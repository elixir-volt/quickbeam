defmodule QuickBEAM.VM.Compiler.WithScopeTest do
  use QuickBEAM.VM.TestCase, async: true

  test "with delete falls through when binding is absent", %{rt: rt} do
    assert_modes(
      rt,
      ~S|function f(){ let obj = {}; let name = "x"; with (obj) { return delete name; } } f()|,
      false
    )
  end

  test "with proxy get throw is catchable", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let p = new Proxy({}, { has(){ return true }, get(){ throw "get" } }); try { with (p) { x } } catch (e) { e }|,
      "get"
    )
  end

  test "with delete jumps through target when binding exists", %{rt: rt} do
    assert_modes(
      rt,
      ~S|function f(){ let obj = {x: 1}; with (obj) { return delete x; } } f()|,
      true
    )
  end
end
