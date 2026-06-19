defmodule QuickBEAM.VM.ObjectModel.CopyTest do
  use QuickBEAM.VM.TestCase, async: true

  test "object spread skips non-enumerable getters", %{rt: rt} do
    assert beam!(rt, """
           let log = [];
           let source = {};
           Object.defineProperty(source, 'a', {
             enumerable: true,
             get() { log.push('get a'); return 1; }
           });
           Object.defineProperty(source, 'b', {
             enumerable: false,
             get() { log.push('get b'); return 2; }
           });
           let out = { ...source };
           log.join(',') + '|' + out.a + '|' + ('b' in out);
           """) == "get a|1|false"
  end

  test "object spread observes proxy ownKeys descriptor get order", %{rt: rt} do
    assert beam!(rt, """
           let log = [];
           let proxy = new Proxy({ a: 1 }, {
             ownKeys() { log.push('ownKeys'); return ['a']; },
             getOwnPropertyDescriptor(_target, key) {
               log.push('desc ' + key);
               return { enumerable: true, configurable: true };
             },
             get(_target, key) { log.push('get ' + key); return 7; }
           });
           let out = { ...proxy };
           log.join(',') + '|' + out.a;
           """) == "ownKeys,desc a,get a|7"
  end

  test "object spread creates own data properties instead of invoking prototype setters", %{
    rt: rt
  } do
    assert beam!(rt, """
           let called = false;
           let proto = { set x(value) { called = true; } };
           let out = { __proto__: proto, ...{ x: 1 } };
           called + '|' + out.x + '|' + Object.prototype.hasOwnProperty.call(out, 'x');
           """) == "false|1|true"
  end
end
