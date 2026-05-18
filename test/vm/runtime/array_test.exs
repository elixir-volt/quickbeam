defmodule QuickBEAM.VM.Runtime.ArrayTest do
  use QuickBEAM.VMCase, async: true

  test "array callbacks skip sparse holes without missing high indexes", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      var calls = [];
      var array = [1];
      array[100001] = 2;
      var every = array.every(function(value, index) { calls.push(index + ':' + value); return true; });
      var mapped = array.map(function(value) { return value + 1; });
      var filtered = array.filter(function(value) { return value > 1; });
      var some = array.some(function(value, index) { calls.push('s' + index + ':' + value); return false; });
      [every, some, calls.join(','), mapped[100001], filtered[0]].join('|')
      """,
      "true|false|0:1,100001:2,s0:1,s100001:2|3|2"
    )
  end

  test "array indexOf searches sparse high indexes", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      var marker = {};
      var array = [];
      array[100001] = marker;
      array.indexOf(marker)
      """,
      100_001
    )
  end

  test "array generic methods treat builtin namespace objects as array-like", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             Math.length = 1;
             Math[0] = 1;
             JSON.length = 1;
             JSON[0] = 2;
             [
               Array.prototype.some.call(Math, function(value, index, object) { return value === 1 && index === 0 && Object.prototype.toString.call(object) === '[object Math]'; }),
               Array.prototype.every.call(JSON, function(value, index, object) { return value === 2 && index === 0 && Object.prototype.toString.call(object) === '[object JSON]'; })
             ].join(',')
             """
           ) == "true,true"
  end

  test "array iterators share ArrayIteratorPrototype", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             var proto = Object.getPrototypeOf([][Symbol.iterator]());
             [
               Object.getPrototypeOf([].entries()) === proto,
               Object.getPrototypeOf([].keys()) === proto,
               Object.getPrototypeOf([].values()) === proto,
               Object.prototype.toString.call([].values())
             ].join('|')
             """
           ) == "true|true|true|[object Array Iterator]"
  end

  test "array flat observes proxy has/get order", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             var getCalls = [], hasCalls = [];
             var handler = {
               get: function(target, key, receiver) { getCalls.push(key); return Reflect.get(target, key, receiver); },
               has: function(target, key) { hasCalls.push(key); return Reflect.has(target, key); }
             };
             var tier2 = new Proxy([4, 3], handler);
             var tier1 = new Proxy([2, [3, [4, 2], 2], 5, tier2, 6], handler);
             Array.prototype.flat.call(tier1, 3);
             getCalls.join(',') + '|' + hasCalls.join(',')
             """
           ) == "length,constructor,0,1,2,3,length,0,1,4|0,1,2,3,0,1,4"
  end
end
