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

    assert_modes(
      rt,
      ~S|let t = {}; Object.defineProperty(t, "x", {get(){return 1}, configurable: false}); let p = new Proxy(t, {set(){ return true; }}); try { Reflect.set(p, "x", 2); "ok"; } catch (e) { e.name; }|,
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

  test "Proxy constructor requires object target and handler", %{rt: rt} do
    assert_modes(rt, ~S|try { new Proxy(1, {}); "ok"; } catch (e) { e.name; }|, "TypeError")
    assert_modes(rt, ~S|try { new Proxy({}, null); "ok"; } catch (e) { e.name; }|, "TypeError")
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

  test "defineProperty trap cannot report incompatible non-configurable definitions", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let target = {}; Object.defineProperty(target, "x", {value: 1, configurable: true}); let p = new Proxy(target, {defineProperty(){ return true; }}); try { Object.defineProperty(p, "x", {value: 1, configurable: false}); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let target = {}; Object.preventExtensions(target); let p = new Proxy(target, {defineProperty(){ return true; }}); try { Reflect.defineProperty(p, "x", {value: 1}); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "Reflect.defineProperty returns false only for internal define failure", %{rt: rt} do
    assert_modes(
      rt,
      ~S|[Reflect.defineProperty(new Proxy({}, {defineProperty(){ return false; }}), "x", {value: 1}), Reflect.defineProperty(Object.preventExtensions({}), "x", {value: 1})].join(",")|,
      "false,false"
    )

    assert_modes(
      rt,
      ~S|try { Reflect.defineProperty({}, "x", 1); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "ownKeys validates array-like trap results and property keys", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let p = new Proxy({}, { ownKeys(){ return {0: "x", length: "1"}; } }); Reflect.ownKeys(p).join(",")|,
      "x"
    )

    assert_modes(
      rt,
      ~S|let p = new Proxy({}, { ownKeys(){ return 1; } }); try { Reflect.ownKeys(p); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let p = new Proxy({}, { ownKeys(){ return [1]; } }); try { Reflect.ownKeys(p); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "ownKeys invariants are enforced through Object.keys", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let target = {}; Object.defineProperty(target, "fixed", {value: 1, configurable: false}); let p = new Proxy(target, {ownKeys(){ return []; }}); try { Object.keys(p); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "preventExtensions traps use handler receiver and revoked checks", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let receiver; let target = {}; Object.preventExtensions(target); let handler = { preventExtensions(){ receiver = this; return true; } }; let p = new Proxy(target, handler); Reflect.preventExtensions(p); receiver === handler|,
      true
    )

    assert_modes(
      rt,
      ~S|let r = Proxy.revocable({}, {}); r.revoke(); try { Reflect.preventExtensions(r.proxy); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "getOwnPropertyDescriptor validates frozen data descriptor compatibility", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let target = {}; Object.defineProperty(target, "x", {value: 1, writable: false, configurable: false}); let p = new Proxy(target, {getOwnPropertyDescriptor(){ return {value: 2, writable: false, configurable: false}; }}); try { Object.getOwnPropertyDescriptor(p, "x"); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "set invariant validation does not invoke target getters", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let calls = 0; let target = {}; Object.defineProperty(target, "x", { get(){ calls++; return 1; }, set: undefined, configurable: false }); let p = new Proxy(target, { set(){ return true; } }); try { Reflect.set(p, "x", 2); } catch (_) {} calls|,
      0
    )
  end

  test "revoked proxies reject has and delete", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = Proxy.revocable({}, {}); r.revoke(); try { "x" in r.proxy; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert {:error, %QuickBEAM.JS.Error{name: "TypeError"}} =
             QuickBEAM.eval(
               rt,
               ~S|let r = Proxy.revocable({}, {}); r.revoke(); delete r.proxy.x;|,
               mode: :beam
             )

    assert_modes(
      rt,
      ~S|let r = Proxy.revocable({}, {}); r.revoke(); try { Object.keys(r.proxy); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let r = Proxy.revocable({}, {}); r.revoke(); try { Reflect.ownKeys(r.proxy); "ok"; } catch (e) { e.name; }|,
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
