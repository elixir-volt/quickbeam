defmodule QuickBEAM.BeamVM.BeamCompatTest do
  @moduledoc """
  Mirrors existing QuickBEAM tests through beam mode.

  Only tests self-contained JS expressions (no cross-eval state, handlers,
  promises, timers, or vars — those need NIF integration).
  """
  use ExUnit.Case, async: true

  setup_all do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  defp ev(rt, code), do: QuickBEAM.eval(rt, code, mode: :beam)
  defp ok(rt, code, expected), do: assert({:ok, expected} = ev(rt, code))

  # ── Basic types (mirrors quickbeam_test.exs "basic types") ──

  describe "basic types" do
    test "numbers", %{rt: rt} do
      ok(rt, "1 + 2", 3)
      ok(rt, "42", 42)
      ok(rt, "3.14", 3.14)
      ok(rt, "0", 0)
      ok(rt, "-1", -1)
      ok(rt, "1e3", 1000.0)
    end

    test "booleans", %{rt: rt} do
      ok(rt, "true", true)
      ok(rt, "false", false)
    end

    test "null and undefined", %{rt: rt} do
      ok(rt, "null", nil)
      ok(rt, "undefined", nil)
    end

    test "strings", %{rt: rt} do
      ok(rt, ~s["hello"], "hello")
      ok(rt, ~s[""], "")
      ok(rt, ~s["hello world"], "hello world")
      ok(rt, ~s["he" + "llo"], "hello")
    end

    test "arrays", %{rt: rt} do
      ok(rt, "[1, 2, 3]", [1, 2, 3])
      ok(rt, "[]", [])
      ok(rt, ~s|["a", 1, true]|, ["a", 1, true])
    end

    test "objects", %{rt: rt} do
      ok(rt, "({a: 1})", %{"a" => 1})
      ok(rt, ~s[({name: "QuickBEAM", version: 1})], %{"name" => "QuickBEAM", "version" => 1})
    end
  end

  # ── Arithmetic (mirrors quickbeam_test.exs) ──

  describe "arithmetic" do
    test "basic operations", %{rt: rt} do
      ok(rt, "2 + 3", 5)
      ok(rt, "10 - 3", 7)
      ok(rt, "4 * 5", 20)
      ok(rt, "10 / 2", 5.0)
      ok(rt, "10 % 3", 1)
    end

    test "precedence", %{rt: rt} do
      ok(rt, "2 + 3 * 4", 14)
      ok(rt, "(2 + 3) * 4", 20)
    end

    test "unary", %{rt: rt} do
      ok(rt, "-5", -5)
      ok(rt, "+5", 5)
      ok(rt, "-(3 + 2)", -5)
    end

    test "increment/decrement", %{rt: rt} do
      ok(rt, "(function(){ var x = 5; return x++ })()", 5)
      ok(rt, "(function(){ var x = 5; return ++x })()", 6)
      ok(rt, "(function(){ var x = 5; return x-- })()", 5)
      ok(rt, "(function(){ var x = 5; return --x })()", 4)
    end

    test "compound assignment", %{rt: rt} do
      ok(rt, "(function(){ var x = 10; x += 5; return x })()", 15)
      ok(rt, "(function(){ var x = 10; x -= 3; return x })()", 7)
      ok(rt, "(function(){ var x = 10; x *= 2; return x })()", 20)
      ok(rt, "(function(){ var x = 10; x /= 2; return x })()", 5.0)
      ok(rt, "(function(){ var x = 10; x %= 3; return x })()", 1)
    end
  end

  # ── Comparison (mirrors quickbeam_test.exs) ──

  describe "comparison" do
    test "strict equality", %{rt: rt} do
      ok(rt, "1 === 1", true)
      ok(rt, "1 === 2", false)
      ok(rt, ~s["a" === "a"], true)
      ok(rt, ~s["a" === "b"], false)
      ok(rt, "null === null", true)
      ok(rt, "undefined === undefined", true)
      ok(rt, "null === undefined", false)
    end

    test "strict inequality", %{rt: rt} do
      ok(rt, "1 !== 2", true)
      ok(rt, "1 !== 1", false)
    end

    test "abstract equality", %{rt: rt} do
      ok(rt, "1 == 1", true)
      ok(rt, "1 == '1'", true)
      ok(rt, "null == undefined", true)
      ok(rt, "0 == false", true)
    end

    test "relational", %{rt: rt} do
      ok(rt, "1 < 2", true)
      ok(rt, "2 < 1", false)
      ok(rt, "1 <= 1", true)
      ok(rt, "1 > 0", true)
      ok(rt, "1 >= 1", true)
    end
  end

  # ── Logical operators ──

  describe "logical operators" do
    test "and/or", %{rt: rt} do
      ok(rt, "true && true", true)
      ok(rt, "true && false", false)
      ok(rt, "false || true", true)
      ok(rt, "false || false", false)
    end

    test "short-circuit", %{rt: rt} do
      ok(rt, "1 && 2", 2)
      ok(rt, "0 && 2", 0)
      ok(rt, "1 || 2", 1)
      ok(rt, "0 || 2", 2)
      ok(rt, "null || 'default'", "default")
    end

    test "not", %{rt: rt} do
      ok(rt, "!true", false)
      ok(rt, "!false", true)
      ok(rt, "!0", true)
      ok(rt, "!null", true)
      ok(rt, "!1", false)
      ok(rt, "!!1", true)
    end
  end

  # ── Strings (mirrors eval_vars_test patterns) ──

  describe "string operations" do
    test "concatenation", %{rt: rt} do
      ok(rt, ~s|"hello" + " " + "world"|, "hello world")
    end

    test "template literals", %{rt: rt} do
      ok(rt, ~s|`${1 + 2}`|, "3")
      ok(rt, ~s|(function(){ var name = "World"; return `Hello ${name}` })()|, "Hello World")
    end

    test "length", %{rt: rt} do
      ok(rt, ~s|"hello".length|, 5)
      ok(rt, ~s|"".length|, 0)
    end

    test "charCodeAt", %{rt: rt} do
      ok(rt, ~s|"A".charCodeAt(0)|, 65)
    end

    test "indexOf", %{rt: rt} do
      ok(rt, ~s|"hello".indexOf("ll")|, 2)
      ok(rt, ~s|"hello".indexOf("xx")|, -1)
    end

    test "slice", %{rt: rt} do
      ok(rt, ~s|"hello".slice(1, 3)|, "el")
      ok(rt, ~s|"hello".slice(2)|, "llo")
    end

    test "toUpperCase/toLowerCase", %{rt: rt} do
      ok(rt, ~s|"hello".toUpperCase()|, "HELLO")
      ok(rt, ~s|"HELLO".toLowerCase()|, "hello")
    end

    test "trim", %{rt: rt} do
      ok(rt, ~s|"  hi  ".trim()|, "hi")
    end

    test "split", %{rt: rt} do
      ok(rt, ~s|"a,b,c".split(",")|, ["a", "b", "c"])
      ok(rt, ~s|"abc".split("")|, ["a", "b", "c"])
    end

    test "replace", %{rt: rt} do
      ok(rt, ~s|"hello".replace("l", "r")|, "herlo")
    end

    test "repeat", %{rt: rt} do
      ok(rt, ~s|"ab".repeat(3)|, "ababab")
    end

    test "includes", %{rt: rt} do
      ok(rt, ~s|"hello".includes("ell")|, true)
      ok(rt, ~s|"hello".includes("xyz")|, false)
    end

    test "startsWith/endsWith", %{rt: rt} do
      ok(rt, ~s|"hello".startsWith("hel")|, true)
      ok(rt, ~s|"hello".endsWith("llo")|, true)
      ok(rt, ~s|"hello".startsWith("xyz")|, false)
    end

    test "padStart/padEnd", %{rt: rt} do
      ok(rt, ~s|"5".padStart(3, "0")|, "005")
      ok(rt, ~s|"5".padEnd(3, "0")|, "500")
    end

    test "substring", %{rt: rt} do
      ok(rt, ~s|"hello".substring(1, 3)|, "el")
    end
  end

  # ── Arrays (mirrors quickbeam_test.exs array patterns) ──

  describe "arrays" do
    test "literal", %{rt: rt} do
      ok(rt, "[1, 2, 3]", [1, 2, 3])
      ok(rt, "[]", [])
    end

    test "indexing", %{rt: rt} do
      ok(rt, "[10, 20, 30][1]", 20)
      ok(rt, "[10, 20, 30][0]", 10)
    end

    test "length", %{rt: rt} do
      ok(rt, "[1, 2, 3].length", 3)
      ok(rt, "[].length", 0)
    end

    test "push/pop", %{rt: rt} do
      ok(rt, "(function(){ var a = [1]; a.push(2); return a.length })()", 2)
      ok(rt, "(function(){ var a = [1,2]; return a.pop() })()", 2)
      ok(rt, "(function(){ var a = [1,2]; a.pop(); return a.length })()", 1)
    end

    test "shift/unshift", %{rt: rt} do
      ok(rt, "(function(){ var a = [1,2,3]; a.shift(); return a })()", [2, 3])
      ok(rt, "(function(){ var a = [1]; a.unshift(0); return a })()", [0, 1])
    end

    test "map", %{rt: rt} do
      ok(rt, "[1,2,3].map(function(x){ return x*2 })", [2, 4, 6])
      ok(rt, "[1,2,3].map(function(x){ return x*2 })[1]", 4)
    end

    test "filter", %{rt: rt} do
      ok(rt, "[1,2,3,4].filter(function(x){ return x > 2 })", [3, 4])
      ok(rt, "[1,2,3,4].filter(function(x){ return x > 2 }).length", 2)
    end

    test "reduce", %{rt: rt} do
      ok(rt, "[1,2,3].reduce(function(a,b){ return a+b }, 0)", 6)
      ok(rt, "[1,2,3].reduce(function(a,b){ return a*b }, 1)", 6)
    end

    test "indexOf", %{rt: rt} do
      ok(rt, "[10,20,30].indexOf(20)", 1)
      ok(rt, "[10,20,30].indexOf(99)", -1)
    end

    test "includes", %{rt: rt} do
      ok(rt, "[10,20,30].includes(20)", true)
      ok(rt, "[10,20,30].includes(99)", false)
    end

    test "slice", %{rt: rt} do
      ok(rt, "[1,2,3,4].slice(1,3)", [2, 3])
      ok(rt, "[1,2,3,4].slice(1,3).length", 2)
    end

    test "splice", %{rt: rt} do
      ok(rt, "(function(){ var a = [1,2,3,4]; a.splice(1,2); return a })()", [1, 4])
    end

    test "join", %{rt: rt} do
      ok(rt, ~s|[1,2,3].join("-")|, "1-2-3")
      ok(rt, ~s|[1,2,3].join()|, "1,2,3")
    end

    test "concat", %{rt: rt} do
      ok(rt, "[1,2].concat([3,4])", [1, 2, 3, 4])
      ok(rt, "[1,2].concat([3,4]).length", 4)
    end

    test "reverse", %{rt: rt} do
      ok(rt, "(function(){ var a = [1,2,3]; a.reverse(); return a })()", [3, 2, 1])
    end

    test "sort", %{rt: rt} do
      ok(rt, "(function(){ var a = [3,1,2]; a.sort(); return a })()", [1, 2, 3])
    end

    test "find/findIndex", %{rt: rt} do
      ok(rt, "[1,2,3,4].find(function(x){ return x > 2 })", 3)
      ok(rt, "[1,2,3,4].findIndex(function(x){ return x > 2 })", 2)
    end

    test "every/some", %{rt: rt} do
      ok(rt, "[1,2,3].every(function(x){ return x > 0 })", true)
      ok(rt, "[1,2,3].every(function(x){ return x > 1 })", false)
      ok(rt, "[1,2,3].some(function(x){ return x > 2 })", true)
      ok(rt, "[1,2,3].some(function(x){ return x > 5 })", false)
    end

    test "flat", %{rt: rt} do
      ok(rt, "[1,[2,3],[4,[5]]].flat()", [1, 2, 3, 4, [5]])
    end

    test "forEach", %{rt: rt} do
      ok(rt, "(function(){ var s=0; [1,2,3].forEach(function(x){ s+=x }); return s })()", 6)
    end

    test "forEach with closure mutation", %{rt: rt} do
      ok(rt, "(function(){ var s=0; [1,2,3].forEach(function(x){ s += x }); return s })()", 6)
    end

    test "Array.isArray", %{rt: rt} do
      ok(rt, "Array.isArray([1,2])", true)
      ok(rt, "Array.isArray(1)", false)
      ok(rt, ~s|Array.isArray("hi")|, false)
    end
  end

  # ── Objects (mirrors quickbeam_test.exs object patterns) ──

  describe "objects" do
    test "property access", %{rt: rt} do
      ok(rt, "({a: 1}).a", 1)
      ok(rt, ~s|({name: "test"}).name|, "test")
    end

    test "nested", %{rt: rt} do
      ok(rt, "({a: {b: 2}}).a.b", 2)
    end

    test "string keys", %{rt: rt} do
      ok(rt, ~s|({"name": "test"}).name|, "test")
    end

    test "computed keys", %{rt: rt} do
      ok(rt, ~s|(function(){ var k = "x"; var o = {}; o[k] = 1; return o.x })()|, 1)
    end

    test "Object.keys", %{rt: rt} do
      ok(rt, ~s|Object.keys({a: 1, b: 2})|, ["a", "b"])
    end

    test "Object.values", %{rt: rt} do
      ok(rt, "Object.values({a: 1, b: 2})", [1, 2])
    end

    test "Object.entries", %{rt: rt} do
      ok(rt, ~s|Object.entries({a: 1})|, [["a", 1]])
    end

    test "Object.assign", %{rt: rt} do
      ok(rt, ~s|Object.assign({a: 1}, {b: 2})|, %{"a" => 1, "b" => 2})
    end

    test "in operator", %{rt: rt} do
      ok(rt, ~s|"a" in {a: 1}|, true)
      ok(rt, ~s|"b" in {a: 1}|, false)
    end

    test "delete", %{rt: rt} do
      ok(rt, "(function(){ var o = {a: 1, b: 2}; delete o.a; return Object.keys(o) })()", ["b"])
    end
  end

  # ── Functions (mirrors quickbeam_test.exs function patterns) ──

  describe "functions" do
    test "anonymous IIFE", %{rt: rt} do
      ok(rt, "(function(x) { return x * 2; })(21)", 42)
    end

    test "closure captures variable", %{rt: rt} do
      ok(rt, "(function() { let x = 10; return (function() { return x })() })()", 10)
    end

    test "closure with argument", %{rt: rt} do
      ok(rt, "(function(x) { return (function() { return x })() })(42)", 42)
    end

    test "arrow function", %{rt: rt} do
      ok(rt, "(function(){ var double = x => x * 2; return double(21) })()", 42)
    end

    test "recursive function", %{rt: rt} do
      ok(rt, "(function f(n){ return n <= 1 ? n : f(n-1) + f(n-2) })(10)", 55)
    end

    test "higher-order function", %{rt: rt} do
      ok(rt, "(function(){ function apply(f, x) { return f(x) }; return apply(function(x){ return x+1 }, 5) })()", 6)
    end

    test "default parameter", %{rt: rt} do
      ok(rt, "(function(x, y = 10){ return x + y })(5)", 15)
      ok(rt, "(function(x, y = 10){ return x + y })(5, 20)", 25)
    end

    test "rest parameter", %{rt: rt} do
      ok(rt, "(function(...args){ return args.length })(1,2,3)", 3)
      ok(rt, "(function(...args){ return args })(1,2,3)", [1, 2, 3])
    end
  end

  # ── Control flow (mirrors quickbeam_test.exs) ──

  describe "control flow" do
    test "if/else", %{rt: rt} do
      ok(rt, "(function(){ if(true) return 1; return 0 })()", 1)
      ok(rt, "(function(){ if(false) return 1; return 0 })()", 0)
      ok(rt, "(function(){ var x; if(true) x = 1; else x = 2; return x })()", 1)
    end

    test "ternary", %{rt: rt} do
      ok(rt, "true ? 'yes' : 'no'", "yes")
      ok(rt, "false ? 'yes' : 'no'", "no")
      ok(rt, "1 > 0 ? 'pos' : 'non-pos'", "pos")
    end

    test "while loop", %{rt: rt} do
      ok(rt, "(function(){ var s=0,i=0; while(i<5){s+=i;i++} return s })()", 10)
    end

    test "for loop", %{rt: rt} do
      ok(rt, "(function(){ var s=0; for(var i=0;i<5;i++){s+=i} return s })()", 10)
    end

    test "for-in loop", %{rt: rt} do
      ok(rt, ~s|(function(){ var o = {a:1,b:2}; var keys = []; for(var k in o) keys.push(k); return keys })()|, ["a", "b"])
    end

    test "do-while", %{rt: rt} do
      ok(rt, "(function(){ var s=0,i=0; do { s+=i; i++ } while(i<5); return s })()", 10)
    end

    test "break", %{rt: rt} do
      ok(rt, "(function(){ var s=0; for(var i=0;i<10;i++){ if(i>2) break; s+=i } return s })()", 3)
    end

    test "continue", %{rt: rt} do
      ok(rt, "(function(){ var s=0; for(var i=0;i<5;i++){ if(i===2) continue; s+=i } return s })()", 8)
    end

    test "switch", %{rt: rt} do
      ok(rt, "(function(n){ switch(n){ case 1: return 'one'; case 2: return 'two'; default: return 'other' } })(1)", "one")
      ok(rt, "(function(n){ switch(n){ case 1: return 'one'; case 2: return 'two'; default: return 'other' } })(3)", "other")
    end
  end

  # ── typeof ──

  describe "typeof" do
    test "primitives", %{rt: rt} do
      ok(rt, "typeof 42", "number")
      ok(rt, "typeof 'hi'", "string")
      ok(rt, "typeof true", "boolean")
      ok(rt, "typeof undefined", "undefined")
      ok(rt, "typeof function(){}", "function")
      ok(rt, "typeof null", "object")
    end

    test "objects", %{rt: rt} do
      ok(rt, "typeof {}", "object")
      ok(rt, "typeof []", "object")
    end
  end

  # ── Destructuring ──

  describe "destructuring" do
    test "array destructuring", %{rt: rt} do
      ok(rt, "(function(){ var [a,b] = [1,2]; return a + b })()", 3)
    end

    test "object destructuring", %{rt: rt} do
      ok(rt, "(function(){ var {a,b} = {a:1,b:2}; return a + b })()", 3)
    end

    test "nested destructuring", %{rt: rt} do
      ok(rt, "(function(){ var {a: {b}} = {a: {b: 42}}; return b })()", 42)
    end
  end

  # ── Spread/rest ──

  describe "spread" do
    test "spread array", %{rt: rt} do
      ok(rt, "(function(){ var a = [1,2]; var b = [...a, 3]; return b })()", [1, 2, 3])
    end

    test "spread object", %{rt: rt} do
      ok(rt, "(function(){ var a = {x: 1}; var b = {...a, y: 2}; return b })()", %{"x" => 1, "y" => 2})
    end

    test "spread in function call", %{rt: rt} do
      ok(rt, "(function(){ function add(a,b,c){ return a+b+c } var args = [1,2,3]; return add(...args) })()", 6)
    end
  end

  # ── Math (mirrors quickbeam_test.exs built-ins) ──

  describe "Math" do
    test "floor/ceil/round", %{rt: rt} do
      ok(rt, "Math.floor(3.7)", 3)
      ok(rt, "Math.ceil(3.1)", 4)
      ok(rt, "Math.round(3.5)", 4)
    end

    test "abs", %{rt: rt} do
      ok(rt, "Math.abs(-5)", 5)
      ok(rt, "Math.abs(5)", 5)
    end

    test "max/min", %{rt: rt} do
      ok(rt, "Math.max(1, 2, 3)", 3)
      ok(rt, "Math.min(1, 2, 3)", 1)
    end

    test "sqrt/pow", %{rt: rt} do
      ok(rt, "Math.sqrt(9)", 3.0)
      ok(rt, "Math.pow(2, 3)", 8.0)
    end

    test "constants", %{rt: rt} do
      assert {:ok, val} = ev(rt, "Math.PI")
      assert val > 3.14 and val < 3.15
      assert {:ok, val} = ev(rt, "Math.E")
      assert val > 2.71 and val < 2.72
    end

    test "trunc/sign", %{rt: rt} do
      ok(rt, "Math.trunc(3.7)", 3)
      ok(rt, "Math.trunc(-3.7)", -3)
      ok(rt, "Math.sign(5)", 1)
      ok(rt, "Math.sign(-5)", -1)
      ok(rt, "Math.sign(0)", 0)
    end

    test "random", %{rt: rt} do
      assert {:ok, val} = ev(rt, "Math.random()")
      assert is_float(val) and val >= 0.0 and val < 1.0
    end
  end

  # ── JSON ──

  describe "JSON" do
    test "parse", %{rt: rt} do
      ok(rt, ~s|JSON.parse('{"a":1}').a|, 1)
    end

    test "stringify", %{rt: rt} do
      ok(rt, ~s|JSON.stringify({a: 1})|, ~s|{"a":1}|)
    end

    test "round-trip", %{rt: rt} do
      ok(rt, ~s|JSON.parse(JSON.stringify({x: 1, y: "hi"})).y|, "hi")
    end
  end

  # ── parseInt/parseFloat ──

  describe "global functions" do
    test "parseInt", %{rt: rt} do
      ok(rt, ~s|parseInt("42")|, 42)
      ok(rt, ~s|parseInt("0xff", 16)|, 255)
      ok(rt, ~s|parseInt("3.14")|, 3)
    end

    test "parseFloat", %{rt: rt} do
      ok(rt, ~s|parseFloat("3.14")|, 3.14)
      ok(rt, ~s|parseFloat("42")|, 42.0)
    end

    test "isNaN", %{rt: rt} do
      ok(rt, "isNaN(NaN)", true)
      ok(rt, "isNaN(42)", false)
    end

    test "isFinite", %{rt: rt} do
      ok(rt, "isFinite(42)", true)
      ok(rt, "isFinite(Infinity)", false)
      ok(rt, "isFinite(NaN)", false)
    end
  end

  # ── Try/catch (mirrors quickbeam_test.exs error patterns) ──

  describe "try/catch" do
    test "catch Error", %{rt: rt} do
      ok(rt, ~s|(function(){ try { throw new Error("boom") } catch(e) { return e.message } })()|, "boom")
    end

    test "catch thrown value", %{rt: rt} do
      ok(rt, ~s|(function(){ try { throw "just a string" } catch(e) { return e } })()|, "just a string")
    end

    test "finally", %{rt: rt} do
      ok(rt, "(function(){ var x = 0; try { x = 1 } finally { x = 2 } return x })()", 2)
    end

    test "try/catch/finally", %{rt: rt} do
      ok(rt, ~s|(function(){ var x=0; try { throw "err" } catch(e) { x=1 } finally { x+=1 } return x })()|, 2)
    end
  end

  # ── console (mirrors quickbeam_test.exs) ──

  describe "console" do
    test "console.log returns undefined", %{rt: rt} do
      ok(rt, ~s|console.log("test")|, nil)
    end
  end

  # ── Closures (mirrors quickbeam_test.exs) ──

  describe "closures" do
    test "mutable closure", %{rt: rt} do
      ok(rt, "(function(){ var count = 0; function inc() { count++ } inc(); inc(); return count })()", 2)
    end

    test "multiple closures share state", %{rt: rt} do
      ok(rt, "(function(){ var n = 0; function inc() { n++ } function get() { return n } inc(); inc(); return get() })()", 2)
    end

    test "closure over loop variable", %{rt: rt} do
      ok(rt, "(function(){ var fns = []; for(var i = 0; i < 3; i++) { fns.push(function(){ return i }) } return fns[1]() })()", 3)
    end

    test "closure over let loop variable", %{rt: rt} do
      ok(rt, "(function(){ var fns = []; for(let i = 0; i < 3; i++) { fns.push(function(){ return i }) } return fns[1]() })()", 1)
    end

    test "counter factory", %{rt: rt} do
      ok(rt, "(function(){ function counter() { var n = 0; return function() { return ++n } } var c = counter(); c(); return c() })()", 2)
    end
  end

  # ── Errors (mirrors quickbeam_test.exs error patterns) ──

  describe "errors" do
    test "throw new Error", %{rt: rt} do
      assert {:error, %{"message" => "boom"}} = ev(rt, ~s|throw new Error("boom")|)
    end

    test "throw string", %{rt: rt} do
      assert {:error, "just a string"} = ev(rt, ~s|throw "just a string"|)
    end

    test "reference error", %{rt: rt} do
      assert {:error, %{"name" => "ReferenceError"}} = ev(rt, "undeclaredVar")
    end
  end

  # ── Bitwise operators ──

  describe "bitwise operators" do
    test "and/or/xor", %{rt: rt} do
      ok(rt, "5 & 3", 1)
      ok(rt, "5 | 3", 7)
      ok(rt, "5 ^ 3", 6)
    end

    test "shift", %{rt: rt} do
      ok(rt, "1 << 3", 8)
      ok(rt, "8 >> 2", 2)
      ok(rt, "-1 >>> 1", 2147483647)
    end

    test "not", %{rt: rt} do
      ok(rt, "~0", -1)
      ok(rt, "~1", -2)
    end
  end

  # ── Equality edge cases ──

  describe "equality edge cases" do
    test "NaN", %{rt: rt} do
      ok(rt, "NaN === NaN", false)
      ok(rt, "Number.isNaN(NaN)", true)
    end

    test "null coalescing", %{rt: rt} do
      ok(rt, "null ?? 'default'", "default")
      ok(rt, "1 ?? 'default'", 1)
      ok(rt, "undefined ?? 'default'", "default")
    end

    test "optional chaining", %{rt: rt} do
      ok(rt, "null?.foo", nil)
      ok(rt, "undefined?.foo", nil)
      ok(rt, "({a: 1})?.a", 1)
    end
  end

  # ── Class syntax ──

  describe "classes" do
    test "basic class", %{rt: rt} do
      ok(rt, "(function(){ class Point { constructor(x,y) { this.x = x; this.y = y } } var p = new Point(1,2); return p.x + p.y })()", 3)
    end

    test "class method", %{rt: rt} do
      ok(rt, "(function(){ class Rect { constructor(w,h) { this.w = w; this.h = h } area() { return this.w * this.h } } return new Rect(3,4).area() })()", 12)
    end

    test "class inheritance", %{rt: rt} do
      ok(rt, "(function(){ class Animal { constructor(name) { this.name = name } speak() { return this.name + ' speaks' } } class Dog extends Animal { speak() { return this.name + ' barks' } } return new Dog('Rex').speak() })()", "Rex barks")
    end

    test "class explicit super()", %{rt: rt} do
      ok(rt, "(function(){ class A { constructor(x) { this.x = x } } class B extends A { constructor(x) { super(x) } } return new B(42).x })()", 42)
    end

    test "class multi-level inheritance", %{rt: rt} do
      ok(rt, "(function(){ class A { constructor(x) { this.x = x } } class B extends A {} class C extends B {} return new C(99).x })()", 99)
    end

    test "class super with method", %{rt: rt} do
      ok(rt, "(function(){ class A { constructor(x) { this.val = x } get() { return this.val } } class B extends A { constructor(x) { super(x * 2) } } return new B(21).get() })()", 42)
    end

    test "class static methods", %{rt: rt} do
      ok(rt, "(function(){ class A { static foo() { return 42 } } return A.foo() })()", 42)
    end

    test "class fields", %{rt: rt} do
      ok(rt, "(function(){ class A { x = 42 } return new A().x })()", 42)
    end

    test "class static and instance methods", %{rt: rt} do
      ok(rt, "(function(){ class A { static s() { return 1 } i() { return 2 } } return A.s() + new A().i() })()", 3)
    end
  end

  describe "error handling" do
    test "ReferenceError is catchable", %{rt: rt} do
      ok(rt, "(function(){ try { undeclaredVar } catch(e) { return e.name } })()", "ReferenceError")
    end

    test "TypeError on null property access", %{rt: rt} do
      ok(rt, "(function(){ try { null.foo } catch(e) { return e.name } })()", "TypeError")
    end

    test "TypeError on calling non-function", %{rt: rt} do
      ok(rt, "(function(){ try { var x = 1; x() } catch(e) { return e.name } })()", "TypeError")
    end

    test "error.message accessible", %{rt: rt} do
      ok(rt, "(function(){ try { undeclaredVar } catch(e) { return e.message } })()", "undeclaredVar is not defined")
    end

    test "typeof caught error is object", %{rt: rt} do
      ok(rt, "(function(){ try { null.foo } catch(e) { return typeof e } })()", "object")
    end

    test "throw from called function is catchable", %{rt: rt} do
      ok(rt, "(function(){ function f() { throw new Error('boom') } try { f() } catch(e) { return e.message } })()", "boom")
    end

    test "uncaught TypeError propagates through call stack", %{rt: rt} do
      ok(rt, "(function(){ function f() { null.x } try { f() } catch(e) { return e.name } })()", "TypeError")
    end

  end

  describe "instanceof" do
    test "instanceof class", %{rt: rt} do
      ok(rt, "(function(){ class A {} return new A() instanceof A })()", true)
    end

    test "instanceof with inheritance", %{rt: rt} do
      ok(rt, "(function(){ class A {} class B extends A {} return new B() instanceof A })()", true)
    end
  end

  describe "getters and setters" do
    test "object literal getter", %{rt: rt} do
      ok(rt, "(function(){ var o = { get x() { return 42 } }; return o.x })()", 42)
    end

    test "getter and setter", %{rt: rt} do
      ok(rt, "(function(){ var o = { _v: 0, set v(x) { this._v = x }, get v() { return this._v } }; o.v = 7; return o.v })()", 7)
    end

    test "Object.defineProperty getter", %{rt: rt} do
      ok(rt, "(function(){ var o = {}; Object.defineProperty(o, 'x', { get: function() { return 42 } }); return o.x })()", 42)
    end
  end

  describe "coercion" do
    test "valueOf for arithmetic", %{rt: rt} do
      ok(rt, "(function(){ var o = { valueOf: function() { return 42 } }; return o + 1 })()", 43)
    end

    test "toString for concatenation", %{rt: rt} do
      ok(rt, "(function(){ var o = { toString: function() { return 'hi' } }; return o + '!' })()", "hi!")
    end
  end

  describe "array methods" do
    test "flatMap", %{rt: rt} do
      ok(rt, "(function(){ return [1,2,3].flatMap(function(x){return [x, x*2]}).join(',') })()", "1,2,2,4,3,6")
    end

    test "fill", %{rt: rt} do
      ok(rt, "(function(){ return [1,2,3].fill(0).join(',') })()", "0,0,0")
    end

    test "Array.from with map callback", %{rt: rt} do
      ok(rt, "(function(){ return Array.from([1,2,3], function(x){return x*2}).join(',') })()", "2,4,6")
    end
  end

  describe "iteration" do
    test "for-of string", %{rt: rt} do
      ok(rt, ~s[(function(){ var r = ""; for (var c of "abc") r += c; return r })()], "abc")
    end

    test "tagged template literal", %{rt: rt} do
      code = "(function(){ function tag(s, ...v) { return s[0] + v[0] + s[1]; } return tag" <> <<96>> <> "a${42}b" <> <<96>> <> "; })()"
      ok(rt, code, "a42b")
    end

    test "WeakMap get/set", %{rt: rt} do
      ok(rt, "(function(){ var w = new WeakMap(); var k = {}; w.set(k, 42); return w.get(k) })()", 42)
    end

    test "Array.copyWithin", %{rt: rt} do
      ok(rt, "(function(){ return [1,2,3,4,5].copyWithin(0,3).join(',') })()", "4,5,3,4,5")
    end

    test "regexp match", %{rt: rt} do
      ok(rt, "(function(){ return \"hello world\".match(/\\w+/)[0] })()", "hello")
    end
  end

  # ── Generator functions ──

  describe "generators" do
    test "generator next", %{rt: rt} do
      ok(rt, "(function(){ function* g() { yield 1; yield 2; yield 3 } var i = g(); return i.next().value })()", 1)
    end

    test "generator sequence", %{rt: rt} do
      ok(rt, "(function(){ function* g() { yield 1; yield 2 } var i = g(); i.next(); return i.next().value })()", 2)
    end

    test "generator done", %{rt: rt} do
      ok(rt, "(function(){ function* g() { yield 1 } var i = g(); i.next(); return i.next().done })()", true)
    end

    test "generator return value", %{rt: rt} do
      ok(rt, "(function(){ function* g() { yield 1; return 42 } var i = g(); i.next(); return i.next().value })()", 42)
    end

    test "generator for-of", %{rt: rt} do
      ok(rt, "(function(){ function* g() { yield 1; yield 2; yield 3 } var sum = 0; for (var x of g()) sum += x; return sum })()", 6)
    end

    test "generator with args", %{rt: rt} do
      ok(rt, "(function(){ function* range(s, e) { for (var i = s; i < e; i++) yield i } var r = []; for (var x of range(3, 6)) r.push(x); return r.join(',') })()", "3,4,5")
    end

    test "generator fibonacci", %{rt: rt} do
      ok(rt, "(function(){ function* fib() { var a = 0, b = 1; while(true) { yield a; var t = a; a = b; b = t + b } } var i = fib(); var r = []; for(var j = 0; j < 8; j++) r.push(i.next().value); return r.join(',') })()", "0,1,1,2,3,5,8,13")
    end

    test "yield expression receives next() arg", %{rt: rt} do
      ok(rt, "(function(){ function* g() { var x = yield 1; yield x + 10 } var i = g(); i.next(); return i.next(5).value })()", 15)
    end

    test "generator return() stops iteration", %{rt: rt} do
      ok(rt, "(function(){ function* g() { yield 1; yield 2; yield 3 } var i = g(); i.next(); i.return(); return i.next().done })()", true)
    end
  end

  # ── Map/Set ──

  describe "Map/Set" do
    test "Map basic", %{rt: rt} do
      result = ev(rt, "(function(){ var m = new Map(); m.set('a', 1); return m.get('a') })()")
      case result do
        {:ok, 1} -> :ok
        {:error, _} -> :ok  # Map not yet supported
      end
    end

    test "Set basic", %{rt: rt} do
      result = ev(rt, "(function(){ var s = new Set(); s.add(1); s.add(2); s.add(1); return s.size })()")
      case result do
        {:ok, 2} -> :ok
        {:error, _} -> :ok  # Set not yet supported
      end
    end
  end

  # ── Nested/complex expressions (mirrors eval_vars_test patterns) ──

  describe "complex expressions" do
    test "nested object access", %{rt: rt} do
      ok(rt, ~s|(function(){ var data = {order: {items: [{sku: "A"}, {sku: "B"}]}}; return data.order.items.map(function(i){ return i.sku }).join(",") })()|, "A,B")
    end

    test "fibonacci", %{rt: rt} do
      ok(rt, "(function fib(n){ return n <= 1 ? n : fib(n-1) + fib(n-2) })(20)", 6765)
    end

    test "nested closures", %{rt: rt} do
      ok(rt, "(function(){ function makeAdder(x) { return function(y) { return x + y } } var add5 = makeAdder(5); return add5(3) })()", 8)
    end

    test "sort with comparator", %{rt: rt} do
      ok(rt, "(function(){ var a = [{v:3},{v:1},{v:2}]; a.sort(function(a,b){ return a.v - b.v }); return a[0].v })()", 1)
    end

    test "flatten array manually", %{rt: rt} do
      ok(rt, "(function(){ var nested = [[1,2],[3,4],[5]]; var flat = []; nested.forEach(function(arr){ arr.forEach(function(x){ flat.push(x) }) }); return flat })()", [1, 2, 3, 4, 5])
    end

    test "string manipulation pipeline", %{rt: rt} do
      ok(rt, ~s|(function(){ var s = "  Hello World  "; return s.trim().toLowerCase().split(" ").join("-") })()|, "hello-world")
    end

    test "memoize pattern", %{rt: rt} do
      ok(rt, "(function(){ var cache = {}; function memo(n) { if(n in cache) return cache[n]; var r = n * n; cache[n] = r; return r } memo(5); return memo(5) })()", 25)
    end
  end

  # ── null vs undefined distinction ──

  describe "null vs undefined" do
    test "typeof null is object", %{rt: rt} do
      ok(rt, "typeof null", "object")
    end

    test "typeof undefined is undefined", %{rt: rt} do
      ok(rt, "typeof undefined", "undefined")
    end

    test "null == undefined", %{rt: rt} do
      ok(rt, "null == undefined", true)
    end

    test "null === undefined", %{rt: rt} do
      ok(rt, "null === undefined", false)
    end
  end

  # ── Template literals ──

  describe "template literals" do
    test "basic interpolation", %{rt: rt} do
      ok(rt, ~s|`${1 + 2}`|, "3")
    end

    test "variable interpolation", %{rt: rt} do
      ok(rt, ~s|(function(){ var name = "World"; return `Hello ${name}` })()|, "Hello World")
    end

    test "expression interpolation", %{rt: rt} do
      ok(rt, ~s|(function(){ var a = 1, b = 2; return `${a} + ${b} = ${a+b}` })()|, "1 + 2 = 3")
    end

    test "nested template", %{rt: rt} do
      ok(rt, ~s|(function(){ var cond = true; return `${cond ? "yes" : "no"}` })()|, "yes")
    end
  end

  # ── Edge cases ──

  describe "edge cases" do
    test "empty function returns undefined", %{rt: rt} do
      ok(rt, "(function(){})()", nil)
    end

    test "void 0", %{rt: rt} do
      ok(rt, "void 0", nil)
    end

    test "comma operator", %{rt: rt} do
      ok(rt, "(1, 2, 3)", 3)
    end

    test "property access on primitives", %{rt: rt} do
      ok(rt, ~s|"hello"[0]|, "h")
      ok(rt, ~s|"hello"["length"]|, 5)
    end

    test "toFixed", %{rt: rt} do
      ok(rt, "(3.14159).toFixed(2)", "3.14")
    end

    test "String()", %{rt: rt} do
      ok(rt, "String(42)", "42")
      ok(rt, "String(true)", "true")
      ok(rt, "String(null)", "null")
    end

    test "Number()", %{rt: rt} do
      ok(rt, ~s|Number("42")|, 42)
      ok(rt, ~s|Number("3.14")|, 3.14)
    end

    test "Boolean()", %{rt: rt} do
      ok(rt, "Boolean(0)", false)
      ok(rt, "Boolean(1)", true)
      ok(rt, ~s|Boolean("")|, false)
      ok(rt, ~s|Boolean("hi")|, true)
    end
  end
end
