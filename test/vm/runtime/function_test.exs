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

  test "builtin constructors observe mutated Function prototype methods", %{rt: rt} do
    assert_modes(
      rt,
      ~S<Function.prototype.toString = Object.prototype.toString; Array.toString()>,
      "[object Function]"
    )
  end

  test "calling saved builtin methods preserves mutated constructor prototypes", %{rt: rt} do
    assert_modes(
      rt,
      ~S<const old = Number.prototype.toLocaleString; const proto = Number.prototype; proto.marker = 123; old.call(0); [Number.prototype === proto, Number.prototype.marker].join("|")>,
      "true|123"
    )
  end
end
