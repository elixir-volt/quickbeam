defmodule QuickBEAM.VM.ObjectModel.PrivateTest do
  use QuickBEAM.VM.TestCase, async: true

  test "private in checks class brands in both BEAM modes", %{rt: rt} do
    assert_modes(
      rt,
      "class C { #x; check(o) { return #x in o; } } let c = new C(); c.check(c)",
      true
    )
  end
end
