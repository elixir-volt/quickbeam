defmodule QuickBEAM.VM.Runtime.ArrayTest do
  use QuickBEAM.VM.TestCase, async: true

  test "array map keeps result array rooted while callbacks allocate", %{rt: rt} do
    code = ~S"""
    var mapped = [1, 2, 3].map(function(value) {
      var keep = [];
      for (var i = 0; i < 210000; i++) {
        keep.push({ index: i });
      }
      return value + 1;
    });
    [
      Array.isArray(mapped),
      Object.getPrototypeOf(mapped) === Array.prototype,
      Object.prototype.toString.call(mapped),
      Object.keys(mapped).join(','),
      Object.getOwnPropertyDescriptor(mapped, 'length').enumerable,
      mapped.join(',')
    ].join('|')
    """

    assert {:ok, "true|true|[object Array]|0,1,2|false|2,3,4"} =
             QuickBEAM.eval(rt, code, mode: :beam, timeout: 30_000)
  end

  test "array concat does not spread primitives with prototype spreadable flag", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      Boolean.prototype[Symbol.isConcatSpreadable] = true;
      Boolean.prototype.length = 1;
      Boolean.prototype[0] = 'spread';
      String.prototype[Symbol.isConcatSpreadable] = true;
      String.prototype.length = 1;
      String.prototype[0] = 'spread';
      var bool = [].concat(true);
      var string = [].concat('x');
      [bool.length, bool[0], string.length, string[0]].join('|')
      """,
      "1|true|1|x"
    )
  end

  test "Array.from keeps custom constructor target rooted while mapper allocates", %{rt: rt} do
    code = ~S"""
    function CustomArray() { return []; }
    var mapped = Array.from.call(CustomArray, [1, 2, 3], function(value) {
      var keep = [];
      for (var i = 0; i < 210000; i++) {
        keep.push({ index: i });
      }
      return value + 1;
    });
    [
      Array.isArray(mapped),
      Object.getPrototypeOf(mapped) === Array.prototype,
      Object.prototype.toString.call(mapped),
      Object.keys(mapped).join(','),
      Object.getOwnPropertyDescriptor(mapped, 'length').enumerable,
      mapped.join(',')
    ].join('|')
    """

    assert {:ok, "true|true|[object Array]|0,1,2|false|2,3,4"} =
             QuickBEAM.eval(rt, code, mode: :beam, timeout: 30_000)
  end

  test "array flatMap keeps result array rooted while callbacks allocate", %{rt: rt} do
    code = ~S"""
    var mapped = [1, 2, 3].flatMap(function(value) {
      var keep = [];
      for (var i = 0; i < 210000; i++) {
        keep.push({ index: i });
      }
      return [value, value + 10];
    });
    [
      Array.isArray(mapped),
      Object.getPrototypeOf(mapped) === Array.prototype,
      Object.prototype.toString.call(mapped),
      Object.keys(mapped).join(','),
      Object.getOwnPropertyDescriptor(mapped, 'length').enumerable,
      mapped.join(',')
    ].join('|')
    """

    assert {:ok, "true|true|[object Array]|0,1,2,3,4,5|false|1,11,2,12,3,13"} =
             QuickBEAM.eval(rt, code, mode: :beam, timeout: 30_000)
  end

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

  test "array iterators read live array state without materializing full list", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             var array = [1];
             var values = array.values();
             var first = values.next().value;
             array.push(2);
             array[2] = 3;
             [first, values.next().value, values.next().value, values.next().done].join('|')
             """
           ) == "1|2|3|true"
  end

  test "array iterators read live element changes", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             var array = [1, 2];
             var entries = array.entries();
             array[0] = 10;
             var first = entries.next().value.join(':');
             array[1] = 20;
             var second = entries.next().value.join(':');
             first + '|' + second
             """
           ) == "0:10|1:20"
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

  test "array slice reads huge proxied array side properties", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             var array = [];
             array['9007199254740989'] = 'a';
             array['9007199254740990'] = 'b';
             var proxy = new Proxy(array, {
               get: function(target, key, receiver) {
                 if (key === 'length') return Math.pow(2, 53) + 2;
                 return Reflect.get(target, key, receiver);
               }
             });
             Array.prototype.slice.call(proxy, -2).join(',')
             """
           ) == "a,b"
  end
end
