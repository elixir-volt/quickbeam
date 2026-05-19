defmodule QuickBEAM.VM.Runtime.SymbolTest do
  use QuickBEAM.VM.TestCase, async: true

  test "anonymous symbol has undefined description", %{rt: rt} do
    assert_modes(rt, ~S|Symbol().description === undefined|, true)
  end

  test "Symbol null description stringifies null", %{rt: rt} do
    assert_modes(rt, ~S|Symbol(null).description|, "null")
  end

  test "anonymous symbol names computed accessor with empty description", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let sym = Symbol(); let obj = { get [sym]() {} }; Object.getOwnPropertyDescriptor(obj, sym).get.name|,
      "get "
    )
  end

  test "computed class property uses symbol description for inferred name", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let sym = Symbol("x"); let obj = { [sym]: class {} }; obj[sym].name|,
      "[x]"
    )
  end

  test "static class methods override inferred constructor name", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let C = class { static name() {} }; [typeof C.name, Object.getOwnPropertyDescriptor(C, "name").enumerable].join(",")|,
      "function,false"
    )
  end
end
