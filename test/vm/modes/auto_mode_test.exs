defmodule QuickBEAM.VM.AutoModeTest do
  use ExUnit.Case, async: true

  test "evaluates through compiler-backed auto mode" do
    {:ok, rt} = QuickBEAM.start(mode: :auto, apis: false)

    try do
      assert {:ok, 3} = QuickBEAM.eval(rt, "function inc(x){ return x + 1 } inc(2)")
    after
      QuickBEAM.stop(rt)
    end
  end

  test "supports explicit auto mode option on a NIF runtime" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      assert {:ok, 7} =
               QuickBEAM.eval(rt, "let o={x:3, inc(y){ return this.x + y }}; o.inc(4)",
                 mode: :auto
               )
    after
      QuickBEAM.stop(rt)
    end
  end

  test "preserves JavaScript throws" do
    {:ok, rt} = QuickBEAM.start(mode: :auto, apis: false)

    try do
      assert {:error, %QuickBEAM.JS.Error{name: "Error", message: "boom"}} =
               QuickBEAM.eval(rt, "throw new Error('boom')")
    after
      QuickBEAM.stop(rt)
    end
  end

  test "evaluates through strict beam compiler mode" do
    {:ok, rt} = QuickBEAM.start(mode: :beam_compiler, apis: false)

    try do
      assert {:ok, 6} = QuickBEAM.eval(rt, "function f(x){ return x * 2 } f(3)")
    after
      QuickBEAM.stop(rt)
    end
  end

  test "supports explicit beam compiler mode option on a NIF runtime" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      assert {:ok, 9} = QuickBEAM.eval(rt, "let o={x:4}; o.x + 5", mode: :beam_compiler)
    after
      QuickBEAM.stop(rt)
    end
  end

  test "compiled finally runs before loop continue" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    code = """
    let seen = "";
    let i = 0;
    while (i < 3) {
      try {
        i++;
        if (i < 3) continue;
      } finally {
        seen += "f";
      }
      seen += "x";
    }
    seen
    """

    try do
      assert {:ok, "fffx"} = QuickBEAM.eval(rt, code, mode: :beam_compiler)
    after
      QuickBEAM.stop(rt)
    end
  end

  test "compiled finally runs before loop break" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    code = """
    let seen = "";
    for (let i = 0; i < 3; i++) {
      try {
        break;
      } finally {
        seen += "f";
      }
      seen += "x";
    }
    seen
    """

    try do
      assert {:ok, "f"} = QuickBEAM.eval(rt, code, mode: :beam_compiler)
    after
      QuickBEAM.stop(rt)
    end
  end

  test "compiled nested catch in finally resumes the original throw" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    code = """
    let seen = "";
    try {
      try {
        throw "outer";
      } finally {
        try {
          throw "inner";
        } catch (e) {
          seen += e;
        }
      }
    } catch (e) {
      seen += e;
    }
    seen
    """

    try do
      assert {:ok, "innerouter"} = QuickBEAM.eval(rt, code, mode: :beam_compiler)
    after
      QuickBEAM.stop(rt)
    end
  end

  test "compiled with statement rejects nullish objects" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    code = """
    let seen = "";
    try { with (undefined) { seen = "bad"; } } catch (e) { seen += e.name; }
    try { with (null) { seen = "bad"; } } catch (e) { seen += ":" + e.name; }
    seen
    """

    try do
      assert {:ok, "TypeError:TypeError"} = QuickBEAM.eval(rt, code, mode: :beam_compiler)
    after
      QuickBEAM.stop(rt)
    end
  end

  test "compiled for-in skips properties deleted during enumeration" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    code = """
    let obj = Object.create(null);
    obj.aa = 1;
    obj.ba = 2;
    obj.ca = 3;
    let seen = "";
    for (let key in obj) {
      delete obj.ba;
      seen += key + obj[key];
    }
    seen
    """

    try do
      assert {:ok, seen} = QuickBEAM.eval(rt, code, mode: :beam_compiler)
      assert seen in ["aa1ca3", "ca3aa1"]
    after
      QuickBEAM.stop(rt)
    end
  end
end
