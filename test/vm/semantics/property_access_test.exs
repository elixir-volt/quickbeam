defmodule QuickBEAM.VM.Semantics.PropertyAccessTest do
  use QuickBEAM.VMCase, async: true

  test "nullish property reads throw in interpreter and compiler", %{rt: rt} do
    for mode <- [:beam, :beam_compiler] do
      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               QuickBEAM.eval(rt, "null.x", mode: mode)

      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               QuickBEAM.eval(rt, "undefined['x']", mode: mode)
    end
  end

  test "nullish property writes throw in interpreter and compiler", %{rt: rt} do
    for mode <- [:beam, :beam_compiler] do
      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               QuickBEAM.eval(rt, "null.x = 1", mode: mode)

      assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
               QuickBEAM.eval(rt, "undefined['x'] = 1", mode: mode)
    end
  end

  test "computed property access converts keys through shared boundary", %{rt: rt} do
    assert_modes(
      rt,
      """
      let log = [];
      let key = { toString() { log.push('key'); return 'x'; } };
      let object = { get x() { log.push('get'); return 1; } };
      object[key];
      log.join(',');
      """,
      "key,get"
    )
  end

  test "computed property key coercion invalidates compiler shape assumptions", %{rt: rt} do
    assert {:ok, 3} =
             QuickBEAM.eval(
               rt,
               """
               let obj = { a: 1 };
               let key = { toString() { obj.b = 2; return 'a'; } };
               obj[key] + obj.b;
               """,
               mode: :beam_compiler
             )
  end
end
