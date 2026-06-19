defmodule QuickBEAM.VM.Runtime.JSONTest do
  use QuickBEAM.VM.TestCase, async: true

  test "array stringify reads elements through property access", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let a = [1]; Object.defineProperty(a, "0", { get() { return 2; }, enumerable: true }); JSON.stringify(a)|,
      "[2]"
    )
  end

  test "array stringify reads inherited indexed properties for holes", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let a = [,]; Object.setPrototypeOf(a, {0: 7}); JSON.stringify(a)|,
      "[7]"
    )
  end

  test "proxy array stringify applies element toJSON and replacer", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let a = [{ toJSON() { return 2; } }]; let p = new Proxy(a, {}); JSON.stringify(p, (k, v) => k === "0" ? v + 1 : v)|,
      "[3]"
    )
  end

  test "proxy object stringify applies property toJSON, replacer, and property list", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let obj = { x: { toJSON() { return 2; } }, y: 3 }; let p = new Proxy(obj, {}); JSON.stringify(p, ["x"])|,
      ~S|{"x":2}|
    )

    assert_modes(
      rt,
      ~S|let obj = { x: { toJSON() { return 2; } } }; let p = new Proxy(obj, {}); JSON.stringify(p, (k, v) => k === "x" ? v + 1 : v)|,
      ~S|{"x":3}|
    )
  end
end
