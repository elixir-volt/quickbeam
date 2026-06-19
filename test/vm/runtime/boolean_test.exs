defmodule QuickBEAM.VM.Runtime.BooleanTest do
  use QuickBEAM.VM.TestCase, async: true

  test "Boolean prototype stores false Boolean data", %{rt: rt} do
    assert_modes(rt, "Boolean.prototype.valueOf()", false)
    assert_modes(rt, "Boolean.prototype.toString()", "false")
  end

  test "Boolean prototype methods reject incompatible receivers", %{rt: rt} do
    assert_beam_error(rt, "Boolean.prototype.valueOf.call({})", "TypeError")
    assert_beam_error(rt, "Boolean.prototype.toString.call(1)", "TypeError")
  end
end
