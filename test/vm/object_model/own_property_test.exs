defmodule QuickBEAM.VM.ObjectModel.OwnPropertyTest do
  use QuickBEAM.VMCase, async: true

  test "Reflect.ownKeys returns array indexes, strings, then symbols in spec order", %{rt: rt} do
    assert beam!(rt, """
           let symbol = Symbol('s');
           let object = {};
           object.b = 1;
           object['2'] = 2;
           object.a = 3;
           object['1'] = 4;
           object[symbol] = 5;
           Reflect.ownKeys(object).map(key => String(key)).join(',');
           """) == "1,2,b,a,Symbol(s)"
  end

  test "Reflect.ownKeys preserves proxy trap order", %{rt: rt} do
    assert beam!(rt, """
           let proxy = new Proxy({}, {
             ownKeys() { return ['b', 'a']; },
             getOwnPropertyDescriptor(_target, _key) {
               return { configurable: true, enumerable: true };
             }
           });
           Reflect.ownKeys(proxy).join(',');
           """) == "b,a"
  end

  test "Reflect.ownKeys includes wrapped string virtual indexes before length", %{rt: rt} do
    assert beam!(rt, "Reflect.ownKeys(Object('ab')).join(',')") == "0,1,length"
  end
end
