defmodule QuickBEAM.VM.ObjectModel.ProxyTest do
  use QuickBEAM.VMCase, async: true

  test "set trap receives receiver for ordinary assignment", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let receiver; let p = new Proxy({}, { set(t, k, v, r) { receiver = r; return true; } }); p.x = 1; receiver === p|,
      true
    )
  end

  test "set invariants use SameValue for numeric values", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let t = {}; Object.defineProperty(t, "x", {value: 0, writable: false, configurable: false}); let p = new Proxy(t, {set(){ return true; }}); p.x = 0.0; t.x|,
      0
    )
  end

  test "set trap cannot report success for getter-only non-configurable accessor", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let t = {}; Object.defineProperty(t, "x", {get(){return 1}, configurable: false}); let p = new Proxy(t, {set(){ return true; }}); try { p.x = 2; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "has trap enforces non-configurable and non-extensible target invariants", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let t = {}; Object.defineProperty(t, "x", {value: 1, configurable: false}); let p = new Proxy(t, {has(){ return false; }}); try { "x" in p; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let t = {x: 1}; Object.preventExtensions(t); let p = new Proxy(t, {has(){ return false; }}); try { "x" in p; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "proxy call and construct require callable and constructable targets", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let p = new Proxy({}, {apply(){ return 1; }}); try { p(); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let p = new Proxy({}, {construct(){ return {}; }}); try { new p(); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end
end
