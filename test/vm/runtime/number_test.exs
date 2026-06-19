defmodule QuickBEAM.VM.Runtime.NumberTest do
  use QuickBEAM.VM.TestCase, async: true

  test "Number constants are non-writable and non-configurable", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      var before = Number.MAX_VALUE;
      Number.MAX_VALUE = 1;
      var deleted = delete Number.MAX_VALUE;
      [Number.MAX_VALUE === before, deleted, Object.getOwnPropertyDescriptor(Number, 'MAX_VALUE').writable, Object.getOwnPropertyDescriptor(Number, 'MAX_VALUE').configurable].join('|')
      """,
      "true|false|false|false"
    )
  end
end
