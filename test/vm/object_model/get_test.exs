defmodule QuickBEAM.VM.ObjectModel.GetTest do
  use QuickBEAM.VM.TestCase, async: true

  test "Reflect.get handles symbol keys with explicit receiver", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let s = Symbol("x"); let receiver = { value: 7 }; let obj = {}; Object.defineProperty(obj, s, { get(){ return this.value; } }); Reflect.get(obj, s, receiver)|,
      7
    )
  end
end
