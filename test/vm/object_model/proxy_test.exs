defmodule QuickBEAM.VM.ObjectModel.ProxyTest do
  use QuickBEAM.VM.TestCase, async: true

  test "set trap receives receiver for ordinary assignment", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let receiver; let p = new Proxy({}, { set(t, k, v, r) { receiver = r; return true; } }); p.x = 1; receiver === p|,
      true
    )
  end

  test "ordinary set forwards missing own properties to prototype proxy", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let seen = []; let handler = { set(t, k, v, r) { seen = [this === handler, t, k, v, r]; return true; } }; let target = {}; let proxy = new Proxy(target, handler); let receiver = Object.create(proxy); receiver.prop = "value"; [seen[0], seen[1] === target, seen[2], seen[3], seen[4] === receiver, Object.hasOwn(receiver, "prop")].join(",")|,
      "true,true,prop,value,true,false"
    )

    assert_modes(
      rt,
      ~S|let seen = []; let handler = { set(t, k, v, r) { seen = [this === handler, t, k, v, r]; return true; } }; let target = {}; let proxy = new Proxy(target, handler); let array = new Array(1); Object.setPrototypeOf(array, proxy); array[0] = 1; [seen[0], seen[1] === target, seen[2], seen[3], seen[4] === array, Object.hasOwn(array, "0")].join(",")|,
      "true,true,0,1,true,false"
    )
  end

  test "set invariants use SameValue for numeric values", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let t = {}; Object.defineProperty(t, "x", {value: 0, writable: false, configurable: false}); let p = new Proxy(t, {set(){ return true; }}); p.x = 0.0; t.x|,
      0
    )
  end

  test "nullish set trap forwards through proxy targets", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let value; let target = { get foo() {}, set bar(v) { value = v; } }; let proxy = new Proxy(new Proxy(target, {}), {}); proxy.bar = 1; value|,
      1
    )

    assert_modes(
      rt,
      ~S|let target = { get foo() {} }; let proxy = new Proxy(new Proxy(target, {}), {}); (function(){ "use strict"; try { proxy.foo = 2; return "ok"; } catch (e) { return e.name; } })()|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let re = /(?:)/g; let proxy = new Proxy(new Proxy(re, {}), {}); [Reflect.set(proxy, "global", true), (proxy.lastIndex = 1, re.lastIndex)].join(",")|,
      "false,1"
    )

    assert_modes(
      rt,
      ~S|let array = [1, 2, 3]; let proxy = new Proxy(new Proxy(array, {}), { set: null }); proxy.length = 0; Object.preventExtensions(array); [(array.length === 0), Reflect.set(proxy, "foo", 2), (function(){ "use strict"; try { proxy[0] = 3; return "ok"; } catch (e) { return e.name; } })()].join(",")|,
      "true,false,TypeError"
    )

    assert_modes(
      rt,
      ~S|let string = new String("str"); let proxy = new Proxy(new Proxy(string, {}), { set: null }); proxy[4] = 1; [string[4], Reflect.set(proxy, "0", "s"), Reflect.set(proxy, "length", 3)].join(",")|,
      "1,false,false"
    )

    assert_modes(
      rt,
      ~S|let fn = function() {}; let proxy = new Proxy(new Proxy(fn, {}), { set: undefined }); [Reflect.set(proxy, "prototype", null), fn.prototype === null, Reflect.set(proxy, "length", 2), (function(){ "use strict"; try { proxy.name = "foo"; return "ok"; } catch (e) { return e.name; } })()].join(",")|,
      "true,true,false,TypeError"
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

  test "in operator converts numeric keys before proxy has trap", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var seen; let target = Object.create([14]); let proxy = new Proxy(target, { has(_target, prop) { seen = prop; return false; } }); let array = []; Object.setPrototypeOf(array, proxy); [1 in array, seen].join(",")|,
      "false,1"
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

  test "Proxy constructor requires new and object target and handler", %{rt: rt} do
    assert_modes(rt, ~S|try { Proxy({}, {}); "ok"; } catch (e) { e.name; }|, "TypeError")
    assert_modes(rt, ~S|try { new Proxy(1, {}); "ok"; } catch (e) { e.name; }|, "TypeError")
    assert_modes(rt, ~S|try { new Proxy({}, null); "ok"; } catch (e) { e.name; }|, "TypeError")
    assert_modes(rt, ~S|Object.prototype.hasOwnProperty.call(Proxy, "prototype")|, false)
  end

  test "proxy newTarget uses target function realm for default prototypes", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let realm = $262.createRealm().global; let newTarget = new realm.Function(); newTarget.prototype = false; let proxy = new Proxy(newTarget, {}); let array = Reflect.construct(Array, [], proxy); [array instanceof realm.Array, Object.getPrototypeOf(array) === realm.Array.prototype].join(",")|,
      "true,true"
    )

    assert_modes(
      rt,
      ~S|let realm = $262.createRealm().global; let newTarget = new realm.Function(); newTarget.prototype = null; let proxy = new Proxy(new Proxy(newTarget, {}), {}); let boxed = Reflect.construct(Boolean, [], proxy); [boxed instanceof realm.Boolean, Object.getPrototypeOf(boxed) === realm.Boolean.prototype].join(",")|,
      "true,true"
    )
  end

  test "Proxy.revocable function metadata matches built-in descriptors", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let d = Object.getOwnPropertyDescriptor(Proxy.revocable, "length"); [Proxy.revocable.length, d.value, d.writable, d.enumerable, d.configurable].join(",")|,
      "2,2,false,false,true"
    )

    assert_modes(
      rt,
      ~S|let revoke = Proxy.revocable({}, {}).revoke; let name = Object.getOwnPropertyDescriptor(revoke, "name"); let length = Object.getOwnPropertyDescriptor(revoke, "length"); [revoke.name, name.value, name.writable, name.enumerable, name.configurable, revoke.length, length.value, length.writable, length.enumerable, length.configurable].join(",")|,
      ",,false,false,true,0,0,false,false,true"
    )

    assert_modes(
      rt,
      ~S|let revoke = Proxy.revocable({}, {}).revoke; try { new revoke(); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "realm objects expose evalScript for revoked proxy errors", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let other = $262.createRealm(); let F = other.evalScript(`(function() { var pair = Proxy.revocable(function(){}, {}); pair.revoke(); return pair.proxy(); })`); try { F(); "ok"; } catch (e) { e instanceof other.global.TypeError; }|,
      true
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

  test "nullish structural traps forward through proxy targets", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let target = { a: 1 }; let proxy = new Proxy(new Proxy(target, {}), { ownKeys: null }); Reflect.ownKeys(proxy).join(",")|,
      "a"
    )

    assert_modes(
      rt,
      ~S|let target = {}; let proxy = new Proxy(new Proxy(target, {}), { preventExtensions: null }); Object.preventExtensions(proxy); Object.isExtensible(target)|,
      false
    )

    assert_modes(
      rt,
      ~S|let target = {}; let proxy = new Proxy(new Proxy(target, {}), { isExtensible: undefined }); Reflect.isExtensible(proxy)|,
      true
    )

    assert_modes(
      rt,
      ~S|let target = { attr: 1 }; let proxy = new Proxy(new Proxy(target, {}), { getOwnPropertyDescriptor: undefined }); [Object.prototype.hasOwnProperty.call(proxy, "attr"), Object.prototype.propertyIsEnumerable.call(proxy, "attr"), Object.getOwnPropertyDescriptor(proxy, "attr").value].join(",")|,
      "true,true,1"
    )

    assert_modes(
      rt,
      ~S|let re = /(?:)/; let proxy = new Proxy(new Proxy(re, {}), { getOwnPropertyDescriptor: undefined }); let desc = Object.getOwnPropertyDescriptor(proxy, "lastIndex"); [desc.value, desc.writable, desc.enumerable, desc.configurable].join(",")|,
      "0,true,false,false"
    )

    assert_modes(
      rt,
      ~S|let re = /(?:)/m; let proxy = new Proxy(new Proxy(re, {}), { has: null }); [Reflect.has(proxy, "ignoreCase"), Symbol.replace in proxy, "lastIndex" in Object.create(proxy)].join(",")|,
      "true,true,true"
    )

    assert_modes(
      rt,
      ~S|let calls = []; let proto = {}; let target = new Proxy(Object.create(proto), { isExtensible(){ calls.push("isExtensible"); return false; }, getPrototypeOf(){ calls.push("getPrototypeOf"); return proto; } }); Object.preventExtensions(target); let proxy = new Proxy(target, { setPrototypeOf(){ calls.push("setPrototypeOf"); return true; } }); [Reflect.setPrototypeOf(proxy, proto), calls.join("/")].join(",")|,
      "true,setPrototypeOf/isExtensible/getPrototypeOf"
    )

    assert_modes(
      rt,
      ~S|let target = {}; Object.preventExtensions(target); let proxy = new Proxy(target, { setPrototypeOf(){ return true; } }); try { Reflect.setPrototypeOf(proxy, {}); "ok"; } catch (e) { e.name; }|,
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
