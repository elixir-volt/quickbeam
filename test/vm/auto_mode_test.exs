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
      assert {:error, %QuickBEAM.JSError{name: "Error", message: "boom"}} =
               QuickBEAM.eval(rt, "throw new Error('boom')")
    after
      QuickBEAM.stop(rt)
    end
  end
end
