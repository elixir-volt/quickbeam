defmodule QuickBEAM.VM.ObjectModel.DefineTest do
  use QuickBEAM.VM.TestCase, async: true

  test "object literal fields define own data properties instead of invoking inherited setters",
       %{rt: rt} do
    assert_modes(
      rt,
      ~S|let proto = { set x(v) { throw "called"; } }; let obj = { __proto__: proto, x: 1 }; obj.x|,
      1
    )
  end

  test "computed object literal keys are coerced before value evaluation", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let value = "bad"; let key = { toString() { value = "ok"; return "p"; } }; let obj = { [key]: value }; obj.p|,
      "ok"
    )
  end

  test "delayed computed property values preserve missing identifier errors", %{rt: rt} do
    assert_modes(rt, ~S|try { ({ [0]: missing }); "no" } catch (e) { e.name }|, "ReferenceError")
  end
end
