defmodule QuickBEAM.VM.Runtime.MathTest do
  use QuickBEAM.VM.TestCase, async: true

  test "abs coerces arguments with ToNumber", %{rt: rt} do
    assert_modes(
      rt,
      ~S|[Math.abs("-2"), Math.abs(null), Math.abs({ valueOf() { return -3; } })].join(",")|,
      "2,0,3"
    )
  end

  test "abs handles missing arguments and rejects BigInt", %{rt: rt} do
    assert_modes(rt, ~S|String(Math.abs())|, "NaN")
    assert_modes(rt, ~S|try { Math.abs(1n); "ok"; } catch (e) { e.name; }|, "TypeError")
  end
end
