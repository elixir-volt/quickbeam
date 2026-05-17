defmodule QuickBEAM.VM.Semantics.EvalTest do
  use QuickBEAM.VMCase, async: true

  alias QuickBEAM.VM.Semantics.Eval

  test "detects simple eval delete identifier expressions" do
    assert Eval.simple_delete_identifier("delete x", %{}) == {:ok, true}
    assert Eval.simple_delete_identifier("delete x", %{"x" => 1}) == {:ok, false}
    assert Eval.simple_delete_identifier("delete obj.x", %{}) == :error
  end

  test "collects simple eval assignment targets" do
    assert Eval.simple_assigned_names("x = 1") == MapSet.new(["x"])
    assert Eval.simple_assigned_names("obj.x = 1") == MapSet.new()
    assert Eval.simple_assigned_names("var x = 1") == MapSet.new()
  end

  test "direct eval delete preserves var binding", %{rt: rt} do
    assert_modes(rt, ~S/var x = 1; var d = eval("delete x"); d + "|" + x/, "false|1")
  end

  test "direct eval assignments to global vars survive later calls", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var assert = {}; assert.sameValue = function () {}; var s1 = "In getter"; var s2 = "In setter"; var s3 = "Modified by setter"; var o; eval("o = {get foo(){ return s1;},set foo(arg){return s2 = s3}};"); assert.sameValue(o.foo, s1); o.foo = 10; s2|,
      "Modified by setter"
    )
  end
end
