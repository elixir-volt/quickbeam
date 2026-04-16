defmodule QuickBEAM.BeamVM.WPTBuiltinsTest do
  @moduledoc """
  WPT-style conformance tests for JS built-in objects in beam mode.
  Tests are self-contained JS expressions — no cross-eval state.
  """
  use ExUnit.Case, async: false

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  defp ev(rt, code), do: QuickBEAM.eval(rt, code, mode: :beam)
  defp ok(rt, code, expected), do: assert({:ok, expected} = ev(rt, code))

  # ═══════════════════════════════════════════════════════════════════════
  # Array.prototype
  # ═══════════════════════════════════════════════════════════════════════

  describe "Array.prototype.push" do
    test "push returns new length", %{rt: rt} do
      ok(rt, "(function(){ var a=[1]; return a.push(2) })()", 2)
    end

    test "push multiple", %{rt: rt} do
      ok(rt, "(function(){ var a=[]; a.push(1,2,3); return a.length })()", 3)
    end

    test "push onto empty", %{rt: rt} do
      ok(rt, "(function(){ var a=[]; a.push(42); return a[0] })()", 42)
    end
  end

  describe "Array.prototype.pop" do
    test "returns last element", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; return a.pop() })()", 3)
    end

    test "modifies array in place", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; a.pop(); return a.length })()", 2)
    end

    test "pop empty returns undefined", %{rt: rt} do
      ok(rt, "(function(){ var a=[]; return a.pop() })()", nil)
    end
  end

  describe "Array.prototype.shift" do
    test "removes first element", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; return a.shift() })()", 1)
    end

    test "remaining elements shift down", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; a.shift(); return a[0] })()", 2)
    end
  end

  describe "Array.prototype.unshift" do
    test "prepends element", %{rt: rt} do
      ok(rt, "(function(){ var a=[2,3]; a.unshift(1); return a[0] })()", 1)
    end

    test "returns new length", %{rt: rt} do
      ok(rt, "(function(){ var a=[2]; return a.unshift(0,1) })()", 3)
    end
  end

  describe "Array.prototype.map" do
    test "transforms each element", %{rt: rt} do
      ok(rt, "[1,2,3].map(function(x){ return x*x })", [1, 4, 9])
    end

    test "passes index as second arg", %{rt: rt} do
      ok(rt, "[10,20,30].map(function(v,i){ return i })", [0, 1, 2])
    end

    test "empty array", %{rt: rt} do
      ok(rt, "[].map(function(x){ return x*2 })", [])
    end
  end

  describe "Array.prototype.filter" do
    test "keeps matching elements", %{rt: rt} do
      ok(rt, "[1,2,3,4,5].filter(function(x){ return x > 3 })", [4, 5])
    end

    test "no matches returns empty", %{rt: rt} do
      ok(rt, "[1,2].filter(function(x){ return x > 10 })", [])
    end

    test "all match returns copy", %{rt: rt} do
      ok(rt, "[1,2,3].filter(function(x){ return true })", [1, 2, 3])
    end
  end

  describe "Array.prototype.reduce" do
    test "sum", %{rt: rt} do
      ok(rt, "[1,2,3,4].reduce(function(a,b){ return a+b }, 0)", 10)
    end

    test "product", %{rt: rt} do
      ok(rt, "[1,2,3,4].reduce(function(a,b){ return a*b }, 1)", 24)
    end

    test "string concatenation", %{rt: rt} do
      ok(rt, ~s|["a","b","c"].reduce(function(a,b){ return a+b }, "")|, "abc")
    end

    test "without initial value", %{rt: rt} do
      ok(rt, "[1,2,3].reduce(function(a,b){ return a+b })", 6)
    end
  end

  describe "Array.prototype.indexOf" do
    test "finds element", %{rt: rt} do
      ok(rt, "[10,20,30,20].indexOf(20)", 1)
    end

    test "not found returns -1", %{rt: rt} do
      ok(rt, "[1,2,3].indexOf(99)", -1)
    end

    test "strict equality", %{rt: rt} do
      ok(rt, ~s|[1,"1",true].indexOf("1")|, 1)
    end
  end

  describe "Array.prototype.includes" do
    test "found", %{rt: rt} do
      ok(rt, "[1,2,3].includes(2)", true)
    end

    test "not found", %{rt: rt} do
      ok(rt, "[1,2,3].includes(99)", false)
    end
  end

  describe "Array.prototype.slice" do
    test "basic range", %{rt: rt} do
      ok(rt, "[1,2,3,4,5].slice(1,3)", [2, 3])
    end

    test "from index to end", %{rt: rt} do
      ok(rt, "[1,2,3,4].slice(2)", [3, 4])
    end

    test "negative index", %{rt: rt} do
      ok(rt, "[1,2,3,4,5].slice(-2)", [4, 5])
    end

    test "does not mutate original", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; a.slice(1); return a.length })()", 3)
    end
  end

  describe "Array.prototype.splice" do
    test "remove elements", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3,4,5]; a.splice(1,2); return a })()", [1, 4, 5])
    end

    test "returns removed elements", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; return a.splice(0,2) })()", [1, 2])
    end
  end

  describe "Array.prototype.join" do
    test "default separator", %{rt: rt} do
      ok(rt, "[1,2,3].join()", "1,2,3")
    end

    test "custom separator", %{rt: rt} do
      ok(rt, ~s|[1,2,3].join(" - ")|, "1 - 2 - 3")
    end

    test "empty separator", %{rt: rt} do
      ok(rt, ~s|[1,2,3].join("")|, "123")
    end
  end

  describe "Array.prototype.concat" do
    test "two arrays", %{rt: rt} do
      ok(rt, "[1,2].concat([3,4])", [1, 2, 3, 4])
    end

    test "does not mutate", %{rt: rt} do
      ok(rt, "(function(){ var a=[1]; a.concat([2]); return a.length })()", 1)
    end
  end

  describe "Array.prototype.reverse" do
    test "reverses in place", %{rt: rt} do
      ok(rt, "(function(){ var a=[1,2,3]; a.reverse(); return a })()", [3, 2, 1])
    end
  end

  describe "Array.prototype.sort" do
    test "default (string) sort", %{rt: rt} do
      ok(rt, "(function(){ var a=[3,1,2]; a.sort(); return a })()", [1, 2, 3])
    end

    test "comparator function", %{rt: rt} do
      ok(rt, "(function(){ var a=[3,1,2]; a.sort(function(a,b){return b-a}); return a })()", [3, 2, 1])
    end
  end

  describe "Array.prototype.find/findIndex" do
    test "find returns first match", %{rt: rt} do
      ok(rt, "[1,2,3,4].find(function(x){ return x > 2 })", 3)
    end

    test "find returns undefined when no match", %{rt: rt} do
      ok(rt, "[1,2].find(function(x){ return x > 10 })", nil)
    end

    test "findIndex returns index", %{rt: rt} do
      ok(rt, "[10,20,30].findIndex(function(x){ return x === 20 })", 1)
    end

    test "findIndex returns -1 when no match", %{rt: rt} do
      ok(rt, "[1,2].findIndex(function(x){ return x > 10 })", -1)
    end
  end

  describe "Array.prototype.every/some" do
    test "every true", %{rt: rt} do
      ok(rt, "[2,4,6].every(function(x){ return x % 2 === 0 })", true)
    end

    test "every false", %{rt: rt} do
      ok(rt, "[2,3,6].every(function(x){ return x % 2 === 0 })", false)
    end

    test "some true", %{rt: rt} do
      ok(rt, "[1,3,4].some(function(x){ return x % 2 === 0 })", true)
    end

    test "some false", %{rt: rt} do
      ok(rt, "[1,3,5].some(function(x){ return x % 2 === 0 })", false)
    end

    test "every on empty is true", %{rt: rt} do
      ok(rt, "[].every(function(x){ return false })", true)
    end

    test "some on empty is false", %{rt: rt} do
      ok(rt, "[].some(function(x){ return true })", false)
    end
  end

  describe "Array.prototype.flat" do
    test "flatten one level", %{rt: rt} do
      ok(rt, "[1,[2,3],[4]].flat()", [1, 2, 3, 4])
    end

    test "doesn't flatten deeper", %{rt: rt} do
      ok(rt, "[1,[2,[3]]].flat()", [1, 2, [3]])
    end
  end

  describe "Array.prototype.forEach" do
    test "iterates all elements", %{rt: rt} do
      ok(rt, "(function(){ var sum=0; [1,2,3].forEach(function(x){ sum+=x }); return sum })()", 6)
    end

    test "passes index", %{rt: rt} do
      ok(rt, "(function(){ var indices=[]; [10,20].forEach(function(v,i){ indices.push(i) }); return indices })()", [0, 1])
    end
  end

  describe "Array.isArray" do
    test "arrays", %{rt: rt} do
      ok(rt, "Array.isArray([1,2])", true)
      ok(rt, "Array.isArray([])", true)
    end

    test "non-arrays", %{rt: rt} do
      ok(rt, "Array.isArray(123)", false)
      ok(rt, ~s|Array.isArray("hello")|, false)
      ok(rt, "Array.isArray(null)", false)
      ok(rt, "Array.isArray(undefined)", false)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # String.prototype
  # ═══════════════════════════════════════════════════════════════════════

  describe "String.prototype.charAt" do
    test "valid index", %{rt: rt} do
      ok(rt, ~s|"hello".charAt(1)|, "e")
    end

    test "out of range returns empty", %{rt: rt} do
      ok(rt, ~s|"hi".charAt(99)|, "")
    end
  end

  describe "String.prototype.charCodeAt" do
    test "ASCII", %{rt: rt} do
      ok(rt, ~s|"ABC".charCodeAt(0)|, 65)
      ok(rt, ~s|"ABC".charCodeAt(2)|, 67)
    end
  end

  describe "String.prototype.indexOf" do
    test "found", %{rt: rt} do
      ok(rt, ~s|"hello world".indexOf("world")|, 6)
    end

    test "not found", %{rt: rt} do
      ok(rt, ~s|"hello".indexOf("xyz")|, -1)
    end

    test "empty needle", %{rt: rt} do
      ok(rt, ~s|"hello".indexOf("")|, 0)
    end
  end

  describe "String.prototype.lastIndexOf" do
    test "finds last occurrence", %{rt: rt} do
      ok(rt, ~s|"abcabc".lastIndexOf("abc")|, 3)
    end
  end

  describe "String.prototype.includes" do
    test "found", %{rt: rt} do
      ok(rt, ~s|"hello world".includes("world")|, true)
    end

    test "not found", %{rt: rt} do
      ok(rt, ~s|"hello".includes("xyz")|, false)
    end
  end

  describe "String.prototype.startsWith/endsWith" do
    test "startsWith match", %{rt: rt} do
      ok(rt, ~s|"hello".startsWith("hel")|, true)
    end

    test "startsWith no match", %{rt: rt} do
      ok(rt, ~s|"hello".startsWith("xyz")|, false)
    end

    test "endsWith match", %{rt: rt} do
      ok(rt, ~s|"hello".endsWith("llo")|, true)
    end

    test "endsWith no match", %{rt: rt} do
      ok(rt, ~s|"hello".endsWith("xyz")|, false)
    end
  end

  describe "String.prototype.slice" do
    test "basic range", %{rt: rt} do
      ok(rt, ~s|"hello".slice(1,3)|, "el")
    end

    test "from start", %{rt: rt} do
      ok(rt, ~s|"hello".slice(0,2)|, "he")
    end

    test "to end", %{rt: rt} do
      ok(rt, ~s|"hello".slice(3)|, "lo")
    end

    test "negative index", %{rt: rt} do
      ok(rt, ~s|"hello".slice(-3)|, "llo")
    end
  end

  describe "String.prototype.substring" do
    test "basic range", %{rt: rt} do
      ok(rt, ~s|"hello".substring(1,3)|, "el")
    end

    test "swaps if start > end", %{rt: rt} do
      ok(rt, ~s|"hello".substring(3,1)|, "el")
    end
  end

  describe "String.prototype.split" do
    test "comma separator", %{rt: rt} do
      ok(rt, ~s|"a,b,c".split(",")|, ["a", "b", "c"])
    end

    test "empty separator splits chars", %{rt: rt} do
      ok(rt, ~s|"abc".split("")|, ["a", "b", "c"])
    end

    test "no match returns whole string", %{rt: rt} do
      ok(rt, ~s|"hello".split("x")|, ["hello"])
    end
  end

  describe "String.prototype.trim/trimStart/trimEnd" do
    test "trim", %{rt: rt} do
      ok(rt, ~s|"  hello  ".trim()|, "hello")
    end

    test "trimStart", %{rt: rt} do
      ok(rt, ~s|"  hello  ".trimStart()|, "hello  ")
    end

    test "trimEnd", %{rt: rt} do
      ok(rt, ~s|"  hello  ".trimEnd()|, "  hello")
    end
  end

  describe "String.prototype.toUpperCase/toLowerCase" do
    test "toUpperCase", %{rt: rt} do
      ok(rt, ~s|"Hello World".toUpperCase()|, "HELLO WORLD")
    end

    test "toLowerCase", %{rt: rt} do
      ok(rt, ~s|"Hello World".toLowerCase()|, "hello world")
    end
  end

  describe "String.prototype.repeat" do
    test "repeat string", %{rt: rt} do
      ok(rt, ~s|"ab".repeat(3)|, "ababab")
    end

    test "repeat 0 times", %{rt: rt} do
      ok(rt, ~s|"abc".repeat(0)|, "")
    end
  end

  describe "String.prototype.padStart/padEnd" do
    test "padStart", %{rt: rt} do
      ok(rt, ~s|"5".padStart(3, "0")|, "005")
    end

    test "padEnd", %{rt: rt} do
      ok(rt, ~s|"5".padEnd(3, "0")|, "500")
    end

    test "no padding needed", %{rt: rt} do
      ok(rt, ~s|"hello".padStart(3)|, "hello")
    end
  end

  describe "String.prototype.replace/replaceAll" do
    test "replace first occurrence", %{rt: rt} do
      ok(rt, ~s|"aabaa".replace("a", "x")|, "xabaa")
    end

    test "replaceAll", %{rt: rt} do
      ok(rt, ~s|"aabaa".replaceAll("a", "x")|, "xxbxx")
    end
  end

  describe "String.prototype.concat" do
    test "concat strings", %{rt: rt} do
      ok(rt, ~s|"hello".concat(" ", "world")|, "hello world")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Object static methods
  # ═══════════════════════════════════════════════════════════════════════

  describe "Object.keys" do
    test "returns own keys", %{rt: rt} do
      ok(rt, "Object.keys({a:1, b:2, c:3})", ["a", "b", "c"])
    end

    test "empty object", %{rt: rt} do
      ok(rt, "Object.keys({})", [])
    end
  end

  describe "Object.values" do
    test "returns own values", %{rt: rt} do
      ok(rt, "Object.values({a:1, b:2})", [1, 2])
    end
  end

  describe "Object.entries" do
    test "returns [key, value] pairs", %{rt: rt} do
      ok(rt, "Object.entries({a:1})", [["a", 1]])
    end
  end

  describe "Object.assign" do
    test "merges objects", %{rt: rt} do
      ok(rt, "Object.assign({a:1}, {b:2})", %{"a" => 1, "b" => 2})
    end

    test "later sources override", %{rt: rt} do
      ok(rt, "Object.assign({a:1}, {a:2})", %{"a" => 2})
    end

    test "multiple sources", %{rt: rt} do
      ok(rt, "Object.assign({}, {a:1}, {b:2})", %{"a" => 1, "b" => 2})
    end
  end

  describe "Object.freeze" do
    test "returns same object", %{rt: rt} do
      ok(rt, "(function(){ var o = {a:1}; return Object.freeze(o) === o })()", true)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Math
  # ═══════════════════════════════════════════════════════════════════════

  describe "Math.floor" do
    test "positive", %{rt: rt} do
      ok(rt, "Math.floor(4.9)", 4)
      ok(rt, "Math.floor(4.0)", 4)
    end

    test "negative", %{rt: rt} do
      ok(rt, "Math.floor(-4.1)", -5)
    end
  end

  describe "Math.ceil" do
    test "positive", %{rt: rt} do
      ok(rt, "Math.ceil(4.1)", 5)
    end

    test "negative", %{rt: rt} do
      ok(rt, "Math.ceil(-4.9)", -4)
    end
  end

  describe "Math.round" do
    test "rounds to nearest", %{rt: rt} do
      ok(rt, "Math.round(4.5)", 5)
      ok(rt, "Math.round(4.4)", 4)
    end
  end

  describe "Math.abs" do
    test "negative becomes positive", %{rt: rt} do
      ok(rt, "Math.abs(-42)", 42)
    end

    test "positive stays", %{rt: rt} do
      ok(rt, "Math.abs(42)", 42)
    end

    test "zero", %{rt: rt} do
      ok(rt, "Math.abs(0)", 0)
    end
  end

  describe "Math.max/min" do
    test "max of numbers", %{rt: rt} do
      ok(rt, "Math.max(1, 5, 3)", 5)
    end

    test "min of numbers", %{rt: rt} do
      ok(rt, "Math.min(1, 5, 3)", 1)
    end

    test "max of two", %{rt: rt} do
      ok(rt, "Math.max(10, 20)", 20)
    end
  end

  describe "Math.sqrt" do
    test "perfect square", %{rt: rt} do
      ok(rt, "Math.sqrt(9)", 3.0)
      ok(rt, "Math.sqrt(16)", 4.0)
    end
  end

  describe "Math.pow" do
    test "integer power", %{rt: rt} do
      ok(rt, "Math.pow(2, 10)", 1024.0)
    end

    test "fractional power", %{rt: rt} do
      ok(rt, "Math.pow(4, 0.5)", 2.0)
    end
  end

  describe "Math.trunc" do
    test "positive", %{rt: rt} do
      ok(rt, "Math.trunc(4.9)", 4)
    end

    test "negative", %{rt: rt} do
      ok(rt, "Math.trunc(-4.9)", -4)
    end
  end

  describe "Math.sign" do
    test "positive", %{rt: rt} do
      ok(rt, "Math.sign(42)", 1)
    end

    test "negative", %{rt: rt} do
      ok(rt, "Math.sign(-42)", -1)
    end

    test "zero", %{rt: rt} do
      ok(rt, "Math.sign(0)", 0)
    end
  end

  describe "Math.random" do
    test "returns 0 <= x < 1", %{rt: rt} do
      assert {:ok, val} = ev(rt, "Math.random()")
      assert is_float(val) and val >= 0.0 and val < 1.0
    end

    test "returns different values", %{rt: rt} do
      {:ok, a} = ev(rt, "Math.random()")
      {:ok, b} = ev(rt, "Math.random()")
      assert a != b
    end
  end

  describe "Math.log/log2/log10" do
    test "natural log", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.log(1)")
      assert_in_delta val, 0.0, 1.0e-10
    end

    test "log2", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.log2(8)")
      assert_in_delta val, 3.0, 1.0e-10
    end

    test "log10", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.log10(1000)")
      assert_in_delta val, 3.0, 1.0e-10
    end
  end

  describe "Math.sin/cos/tan" do
    test "sin(0) = 0", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.sin(0)")
      assert_in_delta val, 0.0, 1.0e-10
    end

    test "cos(0) = 1", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.cos(0)")
      assert_in_delta val, 1.0, 1.0e-10
    end

    test "tan(0) = 0", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.tan(0)")
      assert_in_delta val, 0.0, 1.0e-10
    end
  end

  describe "Math constants" do
    test "PI", %{rt: rt} do
      {:ok, pi} = ev(rt, "Math.PI")
      assert_in_delta pi, :math.pi(), 1.0e-10
    end

    test "E", %{rt: rt} do
      {:ok, e} = ev(rt, "Math.E")
      assert_in_delta e, :math.exp(1), 1.0e-10
    end

    test "LN2", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.LN2")
      assert_in_delta val, :math.log(2), 1.0e-10
    end

    test "SQRT2", %{rt: rt} do
      {:ok, val} = ev(rt, "Math.SQRT2")
      assert_in_delta val, :math.sqrt(2), 1.0e-10
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # JSON
  # ═══════════════════════════════════════════════════════════════════════

  describe "JSON.parse" do
    test "object", %{rt: rt} do
      ok(rt, ~s|JSON.parse('{"a":1,"b":2}')|, %{"a" => 1, "b" => 2})
    end

    test "array", %{rt: rt} do
      ok(rt, ~s|JSON.parse('[1,2,3]')|, [1, 2, 3])
    end

    test "string", %{rt: rt} do
      ok(rt, ~s|JSON.parse('"hello"')|, "hello")
    end

    test "number", %{rt: rt} do
      ok(rt, ~s|JSON.parse('42')|, 42)
    end

    test "boolean", %{rt: rt} do
      ok(rt, ~s|JSON.parse('true')|, true)
      ok(rt, ~s|JSON.parse('false')|, false)
    end

    test "null", %{rt: rt} do
      ok(rt, ~s|JSON.parse('null')|, nil)
    end

    test "nested", %{rt: rt} do
      ok(rt, ~s|JSON.parse('{"a":{"b":[1,2]}}').a.b[1]|, 2)
    end
  end

  describe "JSON.stringify" do
    test "object", %{rt: rt} do
      ok(rt, ~s|JSON.stringify({a: 1})|, ~s|{"a":1}|)
    end

    test "array", %{rt: rt} do
      ok(rt, ~s|JSON.stringify([1,2,3])|, "[1,2,3]")
    end

    test "string", %{rt: rt} do
      ok(rt, ~s|JSON.stringify("hello")|, ~s|"hello"|)
    end

    test "null", %{rt: rt} do
      ok(rt, "JSON.stringify(null)", "null")
    end

    test "boolean", %{rt: rt} do
      ok(rt, "JSON.stringify(true)", "true")
    end

    test "nested round-trip", %{rt: rt} do
      ok(rt, ~s|JSON.parse(JSON.stringify({x: [1,2], y: "z"})).y|, "z")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Number
  # ═══════════════════════════════════════════════════════════════════════

  describe "Number" do
    test "Number() conversion", %{rt: rt} do
      ok(rt, ~s|Number("42")|, 42)
      ok(rt, ~s|Number("3.14")|, 3.14)
      ok(rt, "Number(true)", 1)
      ok(rt, "Number(false)", 0)
      ok(rt, "Number(null)", 0)
    end

    test "Number.isNaN", %{rt: rt} do
      ok(rt, "Number.isNaN(NaN)", true)
      ok(rt, "Number.isNaN(42)", false)
      ok(rt, ~s|Number.isNaN("hello")|, false)
    end

    test "Number.isFinite", %{rt: rt} do
      ok(rt, "Number.isFinite(42)", true)
      ok(rt, "Number.isFinite(Infinity)", false)
      ok(rt, "Number.isFinite(NaN)", false)
    end

    test "Number.isInteger", %{rt: rt} do
      ok(rt, "Number.isInteger(42)", true)
      ok(rt, "Number.isInteger(42.0)", true)
      ok(rt, "Number.isInteger(42.5)", false)
    end

    test "Number.MAX_SAFE_INTEGER", %{rt: rt} do
      ok(rt, "Number.MAX_SAFE_INTEGER", 9007199254740991)
    end
  end

  describe "Number.prototype.toFixed" do
    test "basic", %{rt: rt} do
      ok(rt, "(3.14159).toFixed(2)", "3.14")
    end

    test "zero decimals", %{rt: rt} do
      ok(rt, "(3.7).toFixed(0)", "4")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Global functions
  # ═══════════════════════════════════════════════════════════════════════

  describe "parseInt" do
    test "integer string", %{rt: rt} do
      ok(rt, ~s|parseInt("42")|, 42)
    end

    test "with radix", %{rt: rt} do
      ok(rt, ~s|parseInt("ff", 16)|, 255)
      ok(rt, ~s|parseInt("111", 2)|, 7)
    end

    test "leading whitespace", %{rt: rt} do
      ok(rt, ~s|parseInt("  42  ")|, 42)
    end

    test "stops at non-digit", %{rt: rt} do
      ok(rt, ~s|parseInt("42abc")|, 42)
    end
  end

  describe "parseFloat" do
    test "float string", %{rt: rt} do
      ok(rt, ~s|parseFloat("3.14")|, 3.14)
    end

    test "integer string", %{rt: rt} do
      ok(rt, ~s|parseFloat("42")|, 42.0)
    end
  end

  describe "isNaN" do
    test "NaN", %{rt: rt} do
      ok(rt, "isNaN(NaN)", true)
    end

    test "number", %{rt: rt} do
      ok(rt, "isNaN(42)", false)
    end

    test "string coercion", %{rt: rt} do
      ok(rt, ~s|isNaN("hello")|, true)
      ok(rt, ~s|isNaN("42")|, false)
    end
  end

  describe "isFinite" do
    test "finite number", %{rt: rt} do
      ok(rt, "isFinite(42)", true)
    end

    test "Infinity", %{rt: rt} do
      ok(rt, "isFinite(Infinity)", false)
    end

    test "NaN", %{rt: rt} do
      ok(rt, "isFinite(NaN)", false)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Error constructors
  # ═══════════════════════════════════════════════════════════════════════

  describe "Error" do
    test "Error has message", %{rt: rt} do
      ok(rt, ~s|(function(){ try { throw new Error("boom") } catch(e) { return e.message } })()|, "boom")
    end

    test "Error has name", %{rt: rt} do
      ok(rt, ~s|(function(){ try { throw new Error("x") } catch(e) { return e.name } })()|, "Error")
    end

    test "TypeError name", %{rt: rt} do
      ok(rt, ~s|(function(){ try { throw new TypeError("bad") } catch(e) { return e.name } })()|, "TypeError")
    end

    test "RangeError name", %{rt: rt} do
      ok(rt, ~s|(function(){ try { throw new RangeError("oob") } catch(e) { return e.name } })()|, "RangeError")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Type coercion
  # ═══════════════════════════════════════════════════════════════════════

  describe "type coercion" do
    test "string + number", %{rt: rt} do
      ok(rt, ~s|"num:" + 42|, "num:42")
    end

    test "number + string", %{rt: rt} do
      ok(rt, ~s|42 + "!"|, "42!")
    end

    test "boolean to number", %{rt: rt} do
      ok(rt, "true + 1", 2)
      ok(rt, "false + 1", 1)
    end

    test "null to number", %{rt: rt} do
      ok(rt, "null + 1", 1)
    end

    test "String() conversion", %{rt: rt} do
      ok(rt, "String(42)", "42")
      ok(rt, "String(true)", "true")
      ok(rt, "String(false)", "false")
      ok(rt, "String(null)", "null")
      ok(rt, "String(undefined)", "undefined")
    end

    test "Boolean() conversion", %{rt: rt} do
      ok(rt, "Boolean(0)", false)
      ok(rt, "Boolean(1)", true)
      ok(rt, ~s|Boolean("")|, false)
      ok(rt, ~s|Boolean("x")|, true)
      ok(rt, "Boolean(null)", false)
      ok(rt, "Boolean(undefined)", false)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Operator edge cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "equality edge cases" do
    test "NaN !== NaN", %{rt: rt} do
      ok(rt, "NaN === NaN", false)
      ok(rt, "NaN !== NaN", true)
    end

    test "null == undefined but not ===", %{rt: rt} do
      ok(rt, "null == undefined", true)
      ok(rt, "null === undefined", false)
    end

    test "+0 === -0", %{rt: rt} do
      ok(rt, "+0 === -0", true)
    end
  end

  describe "typeof" do
    test "all types", %{rt: rt} do
      ok(rt, "typeof 42", "number")
      ok(rt, "typeof 3.14", "number")
      ok(rt, ~s|typeof "hello"|, "string")
      ok(rt, "typeof true", "boolean")
      ok(rt, "typeof undefined", "undefined")
      ok(rt, "typeof null", "object")
      ok(rt, "typeof function(){}", "function")
      ok(rt, "typeof {}", "object")
      ok(rt, "typeof []", "object")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Numeric edge cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "integer arithmetic" do
    test "large integers", %{rt: rt} do
      ok(rt, "999999 * 999999", 999998000001)
    end

    test "integer overflow to float", %{rt: rt} do
      ok(rt, "Number.MAX_SAFE_INTEGER + 1 === Number.MAX_SAFE_INTEGER + 2", true)
    end

    test "modulo", %{rt: rt} do
      ok(rt, "17 % 5", 2)
      ok(rt, "-17 % 5", -2)
    end

    test "power operator", %{rt: rt} do
      ok(rt, "2 ** 10", 1024)
    end
  end

  describe "bitwise operations" do
    test "AND", %{rt: rt} do
      ok(rt, "0xFF & 0x0F", 15)
    end

    test "OR", %{rt: rt} do
      ok(rt, "0xF0 | 0x0F", 255)
    end

    test "XOR", %{rt: rt} do
      ok(rt, "0xFF ^ 0x0F", 240)
    end

    test "NOT", %{rt: rt} do
      ok(rt, "~0", -1)
      ok(rt, "~-1", 0)
    end

    test "left shift", %{rt: rt} do
      ok(rt, "1 << 8", 256)
    end

    test "right shift", %{rt: rt} do
      ok(rt, "256 >> 4", 16)
    end

    test "unsigned right shift", %{rt: rt} do
      ok(rt, "-1 >>> 0", 4294967295)
    end
  end
end
