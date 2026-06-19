defmodule QuickBEAM.VM.Semantics.EvalTest do
  use QuickBEAM.VM.TestCase, async: true

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

  test "strict direct eval rejects falsy proxy set through caller binding", %{rt: rt} do
    assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
             QuickBEAM.eval(
               rt,
               ~S|var p=new Proxy({}, {set(){return false}}); eval('"use strict"; p.x=1')|,
               mode: :beam
             )

    assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
             QuickBEAM.eval(
               rt,
               ~S|var p=new Proxy({}, {set(){return false}}); eval('"use strict"; p.x=1')|,
               mode: :beam_compiler
             )
  end

  test "direct eval assignment to local vars does not update global object", %{rt: rt} do
    assert_modes(
      rt,
      ~S<var x = "global"; function noop() {} var local = (function() { var x = "local"; eval("x = 1;"); noop(); return x; })(); [local, x].join("|")>,
      "1|global"
    )
  end

  test "direct eval with spread assignment to local vars does not update global object", %{rt: rt} do
    assert_modes(
      rt,
      ~S<var x = "global"; function noop() {} var args = ["x = 1;"]; var local = (function() { var x = "local"; eval(...args); noop(); return x; })(); [local, x].join("|")>,
      "1|global"
    )
  end

  test "direct eval assignments to global vars survive later calls", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var assert = {}; assert.sameValue = function () {}; var s1 = "In getter"; var s2 = "In setter"; var s3 = "Modified by setter"; var o; eval("o = {get foo(){ return s1;},set foo(arg){return s2 = s3}};"); assert.sameValue(o.foo, s1); o.foo = 10; s2|,
      "Modified by setter"
    )
  end

  test "top-level lexical declarations do not create global object properties", %{rt: rt} do
    assert_modes(rt, ~S|let lexicalGlobal = 1; String(globalThis.lexicalGlobal)|, "undefined")
  end

  test "shadowed eval is an ordinary call in the source compiler", %{rt: rt} do
    assert_modes(
      rt,
      ~S|function f(eval, x) { return eval("x"); } f(function(s) { return s; }, 2)|,
      "x"
    )
  end

  test "direct eval reuses the caller arguments object", %{rt: rt} do
    assert_modes(
      rt,
      ~S"function f(a) { var e = eval('arguments'); var r = arguments; return [e === r, e.length, r.length, e[0], r[0]].join('|'); } f(5)",
      "true|1|1|5|5"
    )
  end
end
