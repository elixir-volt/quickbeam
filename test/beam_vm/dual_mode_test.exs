defmodule QuickBEAM.BeamVM.DualModeTest do
  @moduledoc """
  Runs JS expressions through both NIF and beam mode, asserting identical results.
  Catches semantic divergences between the QuickJS C engine and BEAM interpreter.
  """
  use ExUnit.Case, async: false

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  defp both(rt, code) do
    nif = QuickBEAM.eval(rt, code)
    beam = QuickBEAM.eval(rt, code, mode: :beam)
    {nif, beam}
  end

  defp assert_same(rt, code) do
    {nif, beam} = both(rt, code)
    nif_val = normalize(nif)
    beam_val = normalize(beam)
    assert nif_val == beam_val,
      "NIF vs BEAM mismatch for: #{code}\n  NIF:  #{inspect nif}\n  BEAM: #{inspect beam}"
  end

  defp normalize({:ok, :Infinity}), do: {:ok, :infinity}
  defp normalize({:ok, :"-Infinity"}), do: {:ok, :neg_infinity}
  defp normalize({:ok, :NaN}), do: {:ok, :nan}
  defp normalize({:ok, val}) when is_float(val) do
    if val == Float.round(val, 0) and val == trunc(val) do
      {:ok, trunc(val)}
    else
      {:ok, Float.round(val, 10)}
    end
  end
  defp normalize({:ok, val}), do: {:ok, val}
  defp normalize({:error, _}), do: :error
  defp normalize(other), do: other

  # ══════════════════════════════════════════════════════════════════════
  # Primitives
  # ══════════════════════════════════════════════════════════════════════

  @primitives [
    "42", "0", "-1", "3.14", "-0.5",
    "true", "false", "null", "undefined",
    ~s|"hello"|, ~s|""|, ~s|"hello world"|,
    "1 + 2", "10 - 3", "4 * 5", "10 / 2", "10 % 3",
    "2 + 3 * 4", "(2 + 3) * 4",
    "-5", "+5", "-(3 + 2)",
    "1 === 1", "1 === 2", "1 !== 2",
    ~s|"a" === "a"|, "null === null", "null === undefined",
    "1 == '1'", "null == undefined", "0 == false",
    "1 < 2", "2 < 1", "1 <= 1", "1 > 0", "1 >= 1",
    "true && true", "true && false", "false || true",
    "1 && 2", "0 && 2", "1 || 2", "0 || 2",
    "!true", "!false", "!0", "!null", "!1", "!!1",
    "typeof 42", ~s|typeof "hi"|, "typeof true", "typeof undefined",
    "typeof null", "typeof function(){}", "typeof {}", "typeof []",
    "5 & 3", "5 | 3", "5 ^ 3", "1 << 3", "8 >> 2", "~0", "~1",
    "true ? 'yes' : 'no'", "false ? 'yes' : 'no'",
    "null ?? 'default'", "undefined ?? 'default'", "0 ?? 'default'",
    "null?.foo", "undefined?.bar",
    "({a: 1})?.a",
    "void 0", "(1, 2, 3)",
    "NaN === NaN", "NaN !== NaN",
  ]

  describe "primitives" do
    for code <- @primitives do
      @tag_code code
      test "#{code}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # String built-ins
  # ══════════════════════════════════════════════════════════════════════

  @string_tests [
    ~s|"hello" + " " + "world"|,
    ~s|"hello".length|, ~s|"".length|,
    ~s|"hello".charAt(1)|, ~s|"hi".charAt(99)|,
    ~s|"ABC".charCodeAt(0)|,
    ~s|"hello world".indexOf("world")|, ~s|"hello".indexOf("xyz")|,
    ~s|"hello".indexOf("")|,
    ~s|"abcabc".lastIndexOf("abc")|,
    ~s|"hello world".includes("world")|, ~s|"hello".includes("xyz")|,
    ~s|"hello".startsWith("hel")|, ~s|"hello".endsWith("llo")|,
    ~s|"hello".slice(1, 3)|, ~s|"hello".slice(2)|, ~s|"hello".slice(-3)|,
    ~s|"hello".substring(1, 3)|, ~s|"hello".substring(3, 1)|,
    ~s|"a,b,c".split(",")|, ~s|"abc".split("")|, ~s|"hello".split("x")|,
    ~s|"  hello  ".trim()|,
    ~s|"  hello  ".trimStart()|, ~s|"  hello  ".trimEnd()|,
    ~s|"Hello World".toUpperCase()|, ~s|"Hello World".toLowerCase()|,
    ~s|"ab".repeat(3)|, ~s|"abc".repeat(0)|,
    ~s|"5".padStart(3, "0")|, ~s|"5".padEnd(3, "0")|,
    ~s|"aabaa".replace("a", "x")|, ~s|"aabaa".replaceAll("a", "x")|,
    ~s|"hello".concat(" ", "world")|,
  ]

  describe "String" do
    for code <- @string_tests do
      @tag_code code
      test "#{code}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Array built-ins (self-contained expressions)
  # ══════════════════════════════════════════════════════════════════════

  @array_tests [
    "[1, 2, 3]", "[]",
    "[1, 2, 3][0]", "[1, 2, 3][1]",
    "[1, 2, 3].length", "[].length",
    "[1,2,3].map(function(x){ return x*2 })",
    "[1,2,3].map(function(x){ return x*2 })[1]",
    "[1,2,3,4].filter(function(x){ return x > 2 })",
    "[1,2,3].reduce(function(a,b){ return a+b }, 0)",
    "[1,2,3].reduce(function(a,b){ return a+b })",
    "[10,20,30].indexOf(20)", "[1,2,3].indexOf(99)",
    "[10,20,30].includes(20)", "[10,20,30].includes(99)",
    "[1,2,3,4,5].slice(1,3)", "[1,2,3,4].slice(2)", "[1,2,3,4,5].slice(-2)",
    ~s|[1,2,3].join("-")|, "[1,2,3].join()", ~s|[1,2,3].join("")|,
    "[1,2].concat([3,4])",
    "[1,2,3,4].find(function(x){ return x > 2 })",
    "[1,2].find(function(x){ return x > 10 })",
    "[10,20,30].findIndex(function(x){ return x === 20 })",
    "[2,4,6].every(function(x){ return x % 2 === 0 })",
    "[2,3,6].every(function(x){ return x % 2 === 0 })",
    "[1,3,4].some(function(x){ return x % 2 === 0 })",
    "[1,3,5].some(function(x){ return x % 2 === 0 })",
    "[].every(function(x){ return false })",
    "[].some(function(x){ return true })",
    "[1,[2,3],[4]].flat()",
    "Array.isArray([1,2])", "Array.isArray(123)",
    # mutating (need IIFE)
    "(function(){ var a=[1]; a.push(2); return a.length })()",
    "(function(){ var a=[1,2,3]; return a.pop() })()",
    "(function(){ var a=[1,2,3]; a.pop(); return a.length })()",
    "(function(){ var a=[1,2,3]; a.shift(); return a })()",
    "(function(){ var a=[2,3]; a.unshift(1); return a[0] })()",
    "(function(){ var a=[1,2,3,4,5]; a.splice(1,2); return a })()",
    "(function(){ var a=[1,2,3]; a.reverse(); return a })()",
    "(function(){ var a=[3,1,2]; a.sort(); return a })()",
    "(function(){ var s=0; [1,2,3].forEach(function(x){ s+=x }); return s })()",
  ]

  describe "Array" do
    for code <- @array_tests do
      @tag_code code
      test "#{String.slice(code, 0, 72)}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Object built-ins
  # ══════════════════════════════════════════════════════════════════════

  @object_tests [
    "({a: 1})", "({a: 1}).a", "({a: {b: 2}}).a.b",
    ~s|({name: "test"}).name|,
    "Object.keys({a:1, b:2})", "Object.keys({})",
    "Object.values({a:1, b:2})",
    "Object.entries({a:1})",
    "Object.assign({a:1}, {b:2})",
    "Object.assign({a:1}, {a:2})",
    ~s|"a" in {a:1}|, ~s|"b" in {a:1}|,
    ~s|(function(){ var k="x"; var o={}; o[k]=1; return o.x })()|,
    "(function(){ var o={a:1,b:2}; delete o.a; return Object.keys(o) })()",
  ]

  describe "Object" do
    for code <- @object_tests do
      @tag_code code
      test "#{String.slice(code, 0, 72)}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Math
  # ══════════════════════════════════════════════════════════════════════

  @math_tests [
    "Math.floor(3.7)", "Math.floor(-4.1)",
    "Math.ceil(4.1)", "Math.ceil(-4.9)",
    "Math.round(4.5)", "Math.round(4.4)",
    "Math.abs(-42)", "Math.abs(0)",
    "Math.max(1, 5, 3)", "Math.min(1, 5, 3)",
    "Math.sqrt(9)", "Math.pow(2, 10)",
    "Math.trunc(4.9)", "Math.trunc(-4.9)",
    "Math.sign(42)", "Math.sign(-42)", "Math.sign(0)",
  ]

  describe "Math" do
    for code <- @math_tests do
      @tag_code code
      test "#{code}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # JSON
  # ══════════════════════════════════════════════════════════════════════

  @json_tests [
    ~s|JSON.parse('{"a":1}')|,
    ~s|JSON.parse('[1,2,3]')|,
    ~s|JSON.parse('"hello"')|,
    ~s|JSON.parse('42')|,
    ~s|JSON.parse('true')|,
    ~s|JSON.parse('null')|,
    "JSON.stringify({a: 1})",
    "JSON.stringify([1,2,3])",
    "JSON.stringify(null)",
    "JSON.stringify(true)",
  ]

  describe "JSON" do
    for code <- @json_tests do
      @tag_code code
      test "#{String.slice(code, 0, 72)}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Global functions
  # ══════════════════════════════════════════════════════════════════════

  @global_tests [
    ~s|parseInt("42")|, ~s|parseInt("ff", 16)|, ~s|parseInt("3.14")|,
    ~s|parseFloat("3.14")|,
    "isNaN(NaN)", "isNaN(42)",
    "isFinite(42)", "isFinite(Infinity)", "isFinite(NaN)",
    "String(42)", "String(true)", "String(null)",
    "Boolean(0)", "Boolean(1)", ~s|Boolean("")|, ~s|Boolean("x")|,
    "Number.isNaN(NaN)", "Number.isNaN(42)",
    "Number.isFinite(42)", "Number.isFinite(Infinity)",
    "Number.isInteger(42)", "Number.isInteger(42.5)",
    "Number.MAX_SAFE_INTEGER",
  ]

  describe "global functions" do
    for code <- @global_tests do
      @tag_code code
      test "#{code}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Control flow & functions
  # ══════════════════════════════════════════════════════════════════════

  @flow_tests [
    "(function(x){ return x * 2 })(21)",
    "(function(){ var x=3, y=4; return x+y })()",
    "(function(){ if(true) return 1; return 0 })()",
    "(function(){ var x=5; return x++ })()",
    "(function(){ var x=5; return ++x })()",
    "(function(){ var x=10; x+=5; return x })()",
    "(function(){ var s=0,i=0; while(i<5){s+=i;i++} return s })()",
    "(function(){ var s=0; for(var i=0;i<5;i++){s+=i} return s })()",
    "(function(){ var s=0; for(var i=0;i<10;i++){if(i>2)break;s+=i} return s })()",
    "(function(){ var s=0; for(var i=0;i<5;i++){if(i===2)continue;s+=i} return s })()",
    "(function(){ var s=0,i=0; do{s+=i;i++}while(i<5); return s })()",
    "(function f(n){ return n<=1?n:f(n-1)+f(n-2) })(10)",
    # closures
    "(function(){ let x=10; return (function(){ return x })() })()",
    "(function(x){ return (function(){ return x })() })(42)",
    "(function(){ var count=0; function inc(){count++} inc();inc(); return count })()",
    # try/catch
    ~s|(function(){ try{throw "err"}catch(e){return e} })()|,
    "(function(){ var x=0; try{x=1}finally{x=2} return x })()",
    # switch
    "(function(n){ switch(n){case 1:return 'one';default:return 'other'} })(1)",
    "(function(n){ switch(n){case 1:return 'one';default:return 'other'} })(3)",
    # template literals
    ~s|`${1 + 2}`|,
    # destructuring
    "(function(){ var [a,b]=[1,2]; return a+b })()",
    "(function(){ var {a,b}={a:1,b:2}; return a+b })()",
    # spread
    "(function(){ var a=[1,2]; var b=[...a, 3]; return b })()",
    "(function(){ var a={x:1}; var b={...a, y:2}; return b })()",
    # for-in
    ~s|(function(){ var o={a:1,b:2}; var k=[]; for(var x in o)k.push(x); return k })()|,
    # default params
    "(function(x, y){ if(y===undefined) y=10; return x+y })(5)",
  ]

  describe "control flow & functions" do
    for code <- @flow_tests do
      @tag_code code
      test "#{String.slice(code, 0, 72)}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Type coercion
  # ══════════════════════════════════════════════════════════════════════

  @coercion_tests [
    ~s|"num:" + 42|, ~s|42 + "!"|,
    "true + 1", "false + 1", "null + 1",
    "String(undefined)",
    "Boolean(null)", "Boolean(undefined)",
    "(3.14159).toFixed(2)",
  ]

  describe "type coercion" do
    for code <- @coercion_tests do
      @tag_code code
      test "#{code}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end
# ══════════════════════════════════════════════════════════════════════
  # Serialization edge cases (from core/serialization_test.exs)
  # ══════════════════════════════════════════════════════════════════════

  @serialization_tests [
    "1.0",
    "'héllo'",
    "'日本語'",
    "'Ünïcödé'",
    ~s|"emoji: 🎉"|,
    ~s|"🎉".length|,
    ~s|"日本語".length|,
    "1000000",
"[1, [2, 3], 4]",
    "[1, 'two', true, null]",
    "({})",
    "({a: {b: 1}})",
    "({items: [1, 2, 3]})",
    "({a: {b: {c: 42}}})",
    "({a: {b: {c: {d: 42}}}})",
  ]

  describe "serialization" do
    for code <- @serialization_tests do
      @tag_code code
      test "#{String.slice(code, 0, 72)}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Recursive & complex (from quickbeam_test.exs patterns)
  # ══════════════════════════════════════════════════════════════════════

  @complex_tests [
    "(function f(n){ return n<=1?n:f(n-1)+f(n-2) })(15)",
    "(function f(n){ return n<=1?1:n*f(n-1) })(10)",
    "[1,2,3,4,5].filter(function(x){return x%2===0}).map(function(x){return x*x}).reduce(function(a,b){return a+b},0)",
    "(function(){var n=0; function inc(){n++} inc();inc();inc(); return n})()",
    "(function(){var s=0; [1,2,3,4,5].forEach(function(x){s+=x}); return s})()",
    ~s|(function(){var o={a:{b:{c:42}}}; return o.a.b.c})()|,
    ~s|(function(){ return "  Hello World  ".trim().toLowerCase().split(" ").join("-") })()|,
    "(function(){var a=[5,3,8,1,2]; a.sort(function(a,b){return a-b}); return a})()",
    ~s|(function(){var a=[1,2,3]; a.reverse(); return a.join(",")})()|,
    ~s|JSON.parse(JSON.stringify({x:[1,2],y:"z"})).y|,
    ~s|JSON.parse(JSON.stringify([1,"two",true,null]))|,
    "[[1,2],[3,4],[5,6]][1][1]",
    ~s|"hello world".split(" ").map(function(w){return w.charAt(0).toUpperCase()+w.slice(1)}).join(" ")|,
    ~s|(function(){var o={}; for(var i=0;i<3;i++) o["k"+i]=i; return o.k0+o.k1+o.k2})()|,
    "(function(x){return x>10?'big':x>5?'medium':'small'})(7)",
    "(function(){var x=null; x=x||42; return x})()",
    "(function(){var x=5; x=x||42; return x})()",
    # this-binding
    "(function(){ var o={x:10,f:function(){return this.x}}; return o.f() })()",
    # get_loc0_loc1 ordering
    "(function(){ var a=[2,5,8]; var m=Math.floor(1); return a[m] })()",
    # deep recursion (memoized fib)
    "(function(){ var m={}; function f(n){if(n in m)return m[n];if(n<=1)return n;m[n]=f(n-1)+f(n-2);return m[n]} return f(30) })()",
    # rest params
    "(function(...a){return a.length})(1,2,3)",
    "(function(a,...b){return a+b.length})(10,20,30)",
    # new Array
    "new Array(3).length",
    "new Array(1,2,3).length",
    # string indexing
    ~s|"hello"[1]|,
    ~s|"hello"[0]|,
    # obj method this
    "(function(){var o={x:10,f:function(){return this.x}};return o.f()})()",
    "(function(){var o={n:'world',greet:function(){return 'hello '+this.n}};return o.greet()})()",
    # computed property key
    ~s|(function(){var k="a";return {[k]:1}})()|,
    # rest params edge
    "(function(a,...b){return b})(1,2,3)",
    # lastIndexOf
    "[1,2,3,2,1].lastIndexOf(2)",
    # charAt edge
    ~s|"abc".charAt(-1)|,
    ~s|"abc".charAt(99)|,
    # array toString
    "[1,2,3].toString()",
    # exponent
    "2**10",
    # String.fromCharCode
    "String.fromCharCode(72,101,108,108,111)",
    # JSON.stringify undefined
    "JSON.stringify(undefined)",
    # negative zero
    "1/(-0)===-Infinity",
    "-Infinity",
    "Infinity + 1 === Infinity",
    # special arithmetic
    "Infinity - Infinity",
    "Infinity * 0",
  ]

  describe "complex expressions" do
    for code <- @complex_tests do
      @tag_code code
      test "#{String.slice(code, 0, 72)}", %{rt: rt} do
        assert_same(rt, @tag_code)
      end
    end
  end
end
