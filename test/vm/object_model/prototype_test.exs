defmodule QuickBEAM.VM.ObjectModel.PrototypeTest do
  use QuickBEAM.VM.TestCase, async: true

  test "array property lookup uses receiver-specific prototype", %{rt: rt} do
    assert_modes(rt, ~S|Object.setPrototypeOf([], { x: 1 })["x"]|, 1)
  end

  test "array prototype replacement hides virtual Array prototype methods", %{rt: rt} do
    assert_modes(rt, ~S|let a = []; Object.setPrototypeOf(a, {}); a.map === undefined|, true)
  end
end
