defmodule QuickBEAM.VM.ObjectModel.GeneratorMethodTest do
  use QuickBEAM.VM.TestCase, async: true

  test "generator methods use shared generator function prototype", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let obj = { *method() {} }; Object.getPrototypeOf(obj.method) === Object.getPrototypeOf(function*() {})|,
      true
    )
  end

  test "generator methods expose prototype with generator prototype parent", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let GeneratorPrototype = Object.getPrototypeOf(function*() {}).prototype; let method = { *method() {} }.method; Object.getPrototypeOf(method.prototype) === GeneratorPrototype|
           ) == true
  end
end
