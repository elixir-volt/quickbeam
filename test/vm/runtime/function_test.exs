defmodule QuickBEAM.VM.Runtime.FunctionTest do
  use QuickBEAM.VM.TestCase, async: true

  test "bound functions accept ordinary own properties", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let obj = (function() {}).bind({}); obj.property = 12; [obj.property, obj.hasOwnProperty("property")].join("|")>,
      "12|true"
    )
  end

  test "bound function caller writes are restricted", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let obj = (function() {}).bind({}); try { obj.caller = 12; "no" } catch (e) { e.name }>,
      "TypeError"
    )
  end
end
