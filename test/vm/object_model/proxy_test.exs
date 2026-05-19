defmodule QuickBEAM.VM.ObjectModel.ProxyTest do
  use QuickBEAM.VM.TestCase, async: true

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

  test "get and set traps are called with handler receiver", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let handler = { marker: 42, get() { return this.marker; } }; let p = new Proxy({}, handler); p.x|,
      42
    )

    assert_modes(
      rt,
      ~S|let receiver; let handler = { marker: 42, set() { receiver = this; return true; } }; let p = new Proxy({}, handler); p.x = 1; receiver === handler|,
      true
    )
  end

  test "get and set traps use inherited callable traps and propagate errors", %{rt: rt} do
    assert {:error, %QuickBEAM.JS.Error{message: "boom"}} =
             QuickBEAM.eval(
               rt,
               ~S|let handler = Object.create({ get() { throw new Error("boom"); } }); let p = new Proxy({}, handler); p.x|,
               mode: :beam
             )

    assert_modes(
      rt,
      ~S|let p = new Proxy({}, { get: 1 }); try { p.x; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert {:error, %QuickBEAM.JS.Error{message: "boom"}} =
             QuickBEAM.eval(
               rt,
               ~S|let p = new Proxy({}, { set() { throw new Error("boom"); } }); p.x = 1|,
               mode: :beam
             )

    assert_modes(
      rt,
      ~S|let p = new Proxy({}, { set: 1 }); try { p.x = 1; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "revoked callable proxies cannot be called or constructed", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let r = Proxy.revocable(function(){}, {}); r.revoke(); try { r.proxy(); "ok"; } catch (e) { e.name; }|
           ) == "TypeError"

    assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
             QuickBEAM.eval(
               rt,
               ~S|let r = Proxy.revocable(function(){}, {}); r.revoke(); new r.proxy();|,
               mode: :beam
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
