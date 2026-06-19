defmodule QuickBEAM.JS.CompilerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Compiler, as: JSCompiler
  alias QuickBEAM.VM.Compiler, as: VMCompiler
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter

  describe "compile/1" do
    test "compiles arithmetic expression scripts" do
      assert_compiles_to("1 + 2 * 3", 7)
      assert_compiles_to("2147483647", 2_147_483_647)
    end

    test "compiles local declarations and reads" do
      assert_compiles_to("let x = 1; x + 2", 3)
    end

    test "compiles function declarations and direct calls" do
      assert_compiles_to("function f(a){ return a + 1; } f(2)", 3)
    end

    test "compiles if/else control flow" do
      assert_compiles_to("let x = 0; if (1 > 2) x = 3; else x = 4; x", 4)
    end

    test "assignment expressions return the assigned value" do
      assert_compiles_to("let x = 1; (x = 4) + x", 8)
      assert_compiles_to("x = 4", 4)
    end

    test "compiles constants and unary expressions" do
      assert_compiles_to("'quick'", "quick")
      assert_compiles_to("let x = 2; -x", -2)
      assert_compiles_to("!false", true)
    end

    test "compiles conditional expressions" do
      assert_compiles_to("let x = 1; x === 1 ? 2 : 3", 2)
    end

    test "compiles while loops" do
      assert_compiles_to("let x = 0; while (x < 3) { x = x + 1; } x", 3)
    end

    test "compiles array literals and computed reads" do
      assert_compiles_to("let a = [1, 2, 3]; a.length", 3)
      assert_compiles_to("let a = [1, 2, 3]; a[1]", 2)
    end

    test "compiles object properties" do
      assert_compiles_to("let o = null; o?.x === undefined", true)
      assert_compiles_to("let o = {x: 1}; o?.x", 1)
      assert_compiles_to("let o = {x: 1, y: 2}; o.x + o.y", 3)
      assert_compiles_to("let o = {x: 1}; o.x = 2; o.x", 2)
      assert_compiles_to("let a={x:1}; let b={...a, y:2}; b.y", 2)
      assert_compiles_to("let x = 1; ({x}).x", 1)
      assert_compiles_to("let {x} = {x: 9}; x", 9)
      assert_compiles_to("let {x, y} = {x: 2, y: 3}; x + y", 5)
      assert_compiles_to("let [a,,b] = [1,2,3]; b", 3)
      assert_compiles_to("let k = \"x\"; ({[k]: 2}).x", 2)
      assert_compiles_to("({[1]: 2})[1]", 2)
    end

    test "compiles generic calls and for loops" do
      assert_compiles_to("function f(a,b,c,d){ return a+b+c+d; } f(1,2,3,4)", 10)
      assert_compiles_to("let f = x => x + 1; f(2)", 3)
      assert_compiles_to("class A { static x = 3; static m() { return this.x + 1; } } A.m()", 4)
      assert_compiles_to("[1, 2, 3].map(x => x + 1).join(',')", "2,3,4")

      assert_compiles_to(
        Enum.map_join(0..260, ";", &"function f#{&1}(){return #{rem(&1, 10)}}") <> ";f260()",
        0
      )

      assert_compiles_to("let s=0; for(let i=0; i<4; i=i+1){ s=s+i; } s", 6)

      assert_compiles_to(
        "let s = 0; for (let i = 0; i < 4; i++) { for (let j = 0; j < 3; j++) s += i + j; } s",
        30
      )
    end

    test "compiles loop break and continue" do
      assert_compiles_to("let x=0; while (x < 5) { x=x+1; break; } x", 1)
      assert_compiles_to("let x=0; let y=0; while (x < 3) { x=x+1; continue; y=9; } x+y", 3)

      assert_compiles_to(
        "let out=0; for (let x of [1,2]) { try { throw x } catch (err) { out = out + err; continue; } } out",
        3
      )
    end

    test "compiles do while loops" do
      assert_compiles_to("let x=0; do { x=x+1; } while (x<3); x", 3)
      assert_compiles_to("let x=0; do { break; } while (true); x", 0)
      assert_compiles_to("let x=0; do { x=x+1; continue; x=9; } while (x<3); x", 3)
    end

    test "compiles logical short-circuit expressions" do
      assert_compiles_to("let x=0; true && (x=1); x", 1)
      assert_compiles_to("let x=0; false || (x=1); x", 1)
      assert_compiles_to("null ?? 3", 3)
      assert_compiles_to("0 ?? 3", 0)
    end

    test "compiles bitwise expressions" do
      assert_compiles_to("undefined", :undefined)
      assert_compiles_to("~1", -2)
      assert_compiles_to("1 << 4", 16)
      assert_compiles_to("-8 >> 1", -4)
      assert_compiles_to("-1 >>> 0", 4_294_967_295)
      assert_compiles_to("let x=7; x &= 3; x", 3)
      assert_compiles_to("let x=4; x |= 3; x", 7)
      assert_compiles_to("let x=7; x ^= 3; x", 4)
      assert_compiles_to("Object.is(-0, 0)", false)
      assert_compiles_to("Math.max(1, 2)", 2)
      assert_compiles_to("'x' in {x: 1}", true)
      assert_compiles_to("let o={x:1}; delete o.x; o.x === undefined", true)
      assert_compiles_to("let o={x:1}; delete o['x']; o.x === undefined", true)
      assert_compiles_to("var x = 1; delete x", false)

      assert_compiles_to(
        ~S/var z; var a = {b:{c:2}}; [delete z?.b["c"], delete a?.b["c"], JSON.stringify(a)].join("|")/,
        "true|true|{\"b\":{}}"
      )
    end

    test "compiles sequence expressions" do
      assert_compiles_to("let x=0; (x=1, x+2)", 3)
      assert_compiles_to("let x=0; let y=(x=1, x+2); y+x", 4)
    end

    test "compiles template literals" do
      assert_compiles_to("let x = 2; `${x + 1}`", "3")
      assert_compiles_to("`a${1}b${2}c`", "a1b2c")
    end

    test "compiles simple switch statements" do
      assert_compiles_to(
        "let x = 2; switch (x) { case 1: x = 10; break; case 2: x = 20; break; } x",
        20
      )

      assert_compiles_to("let x = 0; switch (2) { case 1: x = 1; break; default: x = 3; } x", 3)
    end

    test "compiles for-of arrays" do
      assert_compiles_to("let s = 0; for (const x of [1, 2, 3]) s += x; s", 6)
    end

    test "compiles object for-in loops" do
      assert_compiles_to("let s = ''; for (const k in {a: 1, b: 2}) s += k; s.length", 2)

      assert_compiles_to(
        "let o = {a: 1, b: 2}; let s = ''; for (let k in o) { s = s + k; } s.length",
        2
      )
    end

    test "compiles simple throw/catch" do
      assert_compiles_to("try { throw 3; } catch (e) { e + 1; }", 4)
      assert_compiles_to("let x = 0; try { x = 1; } finally { x = x + 1; } x", 2)
    end

    test "compiles constructor calls" do
      assert_compiles_to("function C(){ this.x = 3; } let c = new C(); c.x", 3)

      assert_compiles_to(
        ~S/function *G() {} let ex; try { new G() } catch (err) { ex = err } [ex instanceof TypeError, ex && ex.message].join("|")/,
        "true|G is not a constructor"
      )
    end

    test "compiles simple classes" do
      assert_compiles_to("class A { m() { return 1; } } new A().m()", 1)
      assert_compiles_to("class A { constructor() { this.x = 1; } } new A().x", 1)

      assert_compiles_to(
        "class A { m() { return 1; } } class B extends A { m() { return super.m() + 1; } } new B().m()",
        2
      )
    end

    test "compiles regexp literals" do
      assert_compiles_to("/a+/.test('aa')", true)
    end

    test "compiles update and compound assignments" do
      assert_compiles_to("let x=1; x++; x", 2)
      assert_compiles_to("let x=1; ++x", 2)
      assert_compiles_to("let x=1; x--; x", 0)
      assert_compiles_to("let a=[1]; a[0]++", 1)
      assert_compiles_to("let a=[1]; ++a[0]", 2)
      assert_compiles_to("let o={x:1}; o.x++", 1)
      assert_compiles_to("let o={x:1}; ++o.x", 2)
      assert_compiles_to("let x=3; x += 4; x", 7)
      assert_compiles_to("let x=6; x *= 7; x", 42)
      assert_compiles_to("let a=[1]; (a[0] += 2)", 3)
      assert_compiles_to("let o={x:1}; o.x += 2", 3)
      assert_compiles_to("2 ** 3", 8.0)
      assert_compiles_to("let x=2; x **= 3; x", 8.0)
      assert_compiles_to("let x = 0; x ||= 2; x", 2)
      assert_compiles_to("let x = 1; x &&= 3; x", 3)
      assert_compiles_to("let x = null; x ??= 4; x", 4)
    end

    test "compiles computed array writes" do
      assert_compiles_to("let a=[1]; a[0]=3; a[0]", 3)
      assert_compiles_to("let a=[,1,,2]; a.length", 4)
    end

    test "compiles computed object writes" do
      assert_compiles_to("let o={x:1}; o[\"x\"]=2; o.x", 2)
    end

    test "compiles member assignment expressions" do
      assert_compiles_to("let o={}; let y=(o.x=2); y+o.x", 4)
      assert_compiles_to("let a=[0]; let y=(a[0]=2); y+a[0]", 4)
    end

    test "compiles block scoped function bodies" do
      assert_compiles_to("function f(){ if (true) { var x = 1; } return x; } f()", 1)

      assert_compiles_to(
        "function f(){ if (true) { let x = 1; } return typeof x; } f()",
        "undefined"
      )
    end

    test "compiles function control flow" do
      assert_compiles_to("function f(a,b,c,d,e){return e;} f(1,2,3,4,5)", 5)
      assert_compiles_to("function f(a,b,c,d,e){ e=6; return e; } f(1,2,3,4,5)", 6)
      assert_compiles_to("function f(a,b,c,d,e){ 'use strict'; e=6; return e; } f(1,2,3,4,5)", 6)
      assert_compiles_to("function f(a, b, c) { return a + b + c; } f(...[1, 2, 3])", 6)
      assert_compiles_to("function f(x = 3) { return x; } f() + f(2)", 5)
      assert_compiles_to("function f(...xs) { return xs[0] + xs.length; } f(4, 5)", 6)
      assert_compiles_to("function f({x}, [y]) { return x + y; } f({x: 1}, [2])", 3)
      assert_compiles_to("function make(x){ return function(y){ return x + y; }; } make(2)(3)", 5)

      assert_compiles_to(
        "function make(){ let x = 2; return function(y){ return x + y; }; } make()(3)",
        5
      )

      assert_compiles_to(
        "function f(){ let a=1,b=2; function g(){ return b; } return g(); } f()",
        2
      )

      assert_compiles_to(
        "function f(a,b,c,d){ function g(){ return a+b+c+d; } return g(); } f(1,2,3,4)",
        10
      )

      assert_compiles_to("function f(x){ if (x) return 1; return 2; } f(true)", 1)
      assert_compiles_to("function f(){ while (true) { return 5; } } f()", 5)
      assert_compiles_to("function f(){ for(;;){ break; } return 1; } f()", 1)
    end

    test "compiles method calls" do
      assert_compiles_to("let o={f:function(){return 2}}; o.f()", 2)
      assert_compiles_to("let o={x:1,f:function(){return this.x}}; o.f()", 1)
      assert_compiles_to("let o={x:1,f(){return this.x}}; o.f()", 1)
      assert_compiles_to("let o={f(a,b){return a+b}}; o.f(2,3)", 5)
      assert_compiles_to("let o={f:function(){return 3}}; o[\"f\"]()", 3)
      assert_compiles_to("let a=[function(){return 4}]; a[0]()", 4)
    end

    test "keeps the new frontend compiler separate from the VM compiler" do
      assert {:ok, bytecode} = JSCompiler.compile("1 + 2")
      assert %QuickBEAM.VM.Program{} = bytecode
      assert {:ok, 3} = VMCompiler.invoke(bytecode.value, [])
    end

    test "emits get_var for unresolved globals" do
      assert {:ok, _bytecode} = JSCompiler.compile("missing")
    end

    test "compiles direct eval with caller arguments" do
      assert_compiles_to("function f(){ return eval('arguments[0]') } f(7)", 7)
    end

    test "literal direct eval var declarations do not write lexical slots" do
      assert_compiles_error_name(~S|let x; eval("var x = 1"); x|, "SyntaxError")
      assert_compiles_to(~S|var x; eval("var x = 1"); x|, 1)
      assert_compiles_to(~S|var x = 1; eval("var x;"); x|, 1)
    end

    test "throws SyntaxError for direct eval parse errors" do
      assert_compiles_to(
        ~S|let ex; try { eval('(function({await}) { "use strict"; return 1; })({})') } catch (err) { ex = err } ex instanceof SyntaxError|,
        true
      )
    end

    test "preserves RequireObjectCoercible checks for empty object bindings" do
      assert_compiles_error_name(~S|let {} = null; "unreachable"|, "TypeError")
    end

    test "reuses computed object binding keys for rest exclusions" do
      assert_compiles_to(
        ~S/let i = 0; let keys = ["a", "b"]; let { [keys[i++]]: v, ...rest } = { a: 1, b: 2 }; [i, v, rest.a, rest.b].join("|")/,
        "1|1||2"
      )
    end

    test "compiles object rest assignment destructuring" do
      assert_compiles_to(~S|let r; ({ ...r } = { a: 1 }); r.a|, 1)
      assert_compiles_to(~S|let r, _; ({ a: _, ...r } = { a: 1, b: 2 }); r.b|, 2)
    end

    test "compiles nested object binding patterns" do
      assert_compiles_to(~S|let { a: { b }, ...rest } = { a: { b: 1 }, c: 2 }; b + rest.c|, 3)
      assert_compiles_to(~S|let { a: [b], ...rest } = { a: [1], c: 2 }; b + rest.c|, 3)
    end

    test "for-of compiles object assignment patterns" do
      assert_compiles_to(
        ~S|var x, counter = 0; for ({ ['x' + 'y']: x } of [{ x: 1, xy: 23, y: 2 }]) { counter += x; } counter|,
        23
      )

      assert_compiles_to(
        ~S|var a = "foo", b, rest; var counter = 0; for ({[a]:b, ...rest} of [{ foo: 1, bar: 2, baz: 3 }]) { counter += b + rest.bar + rest.baz; } counter|,
        6
      )

      assert_compiles_to(
        ~S|var a = 1, b, rest; for ({[a]:b, ...rest} of [{[a]: 1, bar: 2 }]) {} rest["1"]|,
        :undefined
      )

      assert_compiles_to(
        ~S|var a = [1], b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} rest["1"]|,
        :undefined
      )

      assert_compiles_to(
        ~S|var a = "1", b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} rest["1"]|,
        :undefined
      )

      assert_compiles_to(
        ~S|var a = 1.0, b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} rest["1"]|,
        :undefined
      )

      assert_compiles_to(
        ~S|var a = 1e0, b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} rest["1"]|,
        :undefined
      )

      assert_compiles_to(
        ~S|var a = 1, b, rest; for ({[a]:b, ...rest} of [{[a]: 1, bar: 2 }]) {} b + rest.bar|,
        3
      )

      assert_compiles_to(
        ~S|var a = [1], b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} b + rest.bar|,
        3
      )

      assert_compiles_to(
        ~S|var a = "1", b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} b + rest.bar|,
        3
      )

      assert_compiles_to(
        ~S|var a = 1.0, b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} b + rest.bar|,
        3
      )

      assert_compiles_to(
        ~S|var a = 1e0, b, rest; for ({[a]:b, ...rest} of [{"1": 1, bar: 2 }]) {} b + rest.bar|,
        3
      )

      assert_compiles_to(
        ~S|var x; for ({ ["x" + "y"]: x } of [{ x: 1, xy: 23, y: 2 }]) {} x|,
        23
      )

      assert_compiles_to(
        ~S|var a="foo", b, rest; for ({[a]:b, ...rest} of [{ foo: 1, bar: 2, baz: 3 }]) {} b + rest.bar + rest.baz|,
        6
      )
    end

    test "for-of preserves completion values and assignment heads" do
      assert_compiles_to(~S|for (let x of []) { 1 }|, :undefined)
      assert_compiles_to(~S|for (let x of [0]) { 3 }|, 3)
      assert_compiles_to(~S|let x; for (x of [0]) { 4 }|, 4)
      assert_compiles_to(~S|let x; for (x of []) { 4 }|, :undefined)
      assert_compiles_to(~S|for (let x of [0]) { 3; break }|, 3)
      assert_compiles_to(~S|let x; for (x of [0]) { 3; break }|, 3)

      assert_compiles_to(
        ~S|let iter={ closed:0, [Symbol.iterator]() { return this; }, next() { return {value:1, done:false}; }, return() { this.closed++; return {}; } }; for (let x of iter) { break; } iter.closed|,
        1
      )

      assert_compiles_to(
        ~S|let iter={ closed:0, [Symbol.iterator]() { return this; }, next() { return {value:1, done:false}; }, return() { this.closed++; return {}; } }; function f(){ for (let x of iter) { return 7; } } f(); iter.closed|,
        1
      )

      assert_compiles_to(
        ~S|let iter={ closed:0, [Symbol.iterator]() { return this; }, next() { return {value:1, done:false}; }, return() { this.closed++; return {}; } }; function f(){ for (let x of iter) { throw new Error("boom"); } } try { f(); } catch (_) {} iter.closed|,
        1
      )

      assert_compiles_to(
        ~S|let iter={ closed:0, [Symbol.iterator]() { return this; }, next() { return {value:1, done:false}; }, return() { this.closed++; return {}; } }; outer: do { for (let x of iter) { continue outer; } } while(false); iter.closed|,
        1
      )

      assert_compiles_to(
        ~S|let iter={ closed:0, count:0, [Symbol.iterator]() { return this; }, next() { this.count++; return {value:this.count, done:this.count > 2}; }, return() { this.closed++; return {}; } }; for (let x of iter) { try { throw new Error("boom"); } catch (_) { continue; } } iter.closed|,
        0
      )
    end

    test "block lexical scopes stay aligned through nested blocks and with" do
      assert_compiles_to(~S|{ { let x = 1; } } typeof x|, "undefined")
      assert_compiles_to(~S|let outer = 1; with ({}) { let outer = 2; } outer|, 1)
    end

    test "block lexical patterns keep coercion checks without leaking bindings" do
      assert_compiles_error_name(~S|{ let { a } = null; } "unreachable"|, "TypeError")
      assert_compiles_error_name(~S|{ let [a] = undefined; } "unreachable"|, "TypeError")
      assert_compiles_to(~S|{ let { a } = { a: 1 }; a }|, 1)
      assert_compiles_to(~S|{ let [a] = [1]; a }|, 1)
      assert_compiles_to(~S|{ let { a } = { a: 1 }; } typeof a|, "undefined")

      assert_compiles_to(
        ~S|let a = 2; let inner; { let { a } = { a: 1 }; inner = a; } inner + a|,
        3
      )
    end

    test "computed property reads perform ToPropertyKey" do
      assert_compiles_to(
        ~S|let key = { toString() { globalThis.hit = 1; return "x"; } }; let obj = { x: 2 }; obj[key] + hit|,
        3
      )
    end

    test "compiled globalThis field writes update global bindings" do
      assert_compiles_to(~S|globalThis.compiledGlobal = 1; compiledGlobal|, 1)
    end

    test "object methods and accessors use method descriptors" do
      assert_compiles_to(
        ~S/let k = "x"; let obj = { [k]() { return 1; }, get ["y"]() { return 2; } }; [obj.x(), obj.y, Object.getOwnPropertyDescriptor(obj, "x").enumerable].join("|")/,
        "1|2|true"
      )
    end

    test "static class methods use method descriptors" do
      assert_compiles_to(
        ~S/class C { static name() {} static ["x"]() {} } [typeof C.name, Object.getOwnPropertyDescriptor(C, "x").enumerable, typeof C.x].join("|")/,
        "function|false|function"
      )
    end

    test "preserves object property order in compiled mode" do
      assert_compiles_to(
        ~S|let a = { get: 2, set: 3, async: 4, get a(){ return this.get } }; JSON.stringify(a)|,
        ~S|{"get":2,"set":3,"async":4,"a":2}|
      )

      assert_compiles_to(
        ~S|let o = Object.create({}, {x:{value:2, enumerable:true}}); o.x + ":" + Object.keys(o).length|,
        "2:1"
      )
    end
  end

  defp assert_compiles_to(source, expected) do
    Task.async(fn ->
      Heap.reset()
      assert {:ok, bytecode} = JSCompiler.compile(source)

      assert {:ok, ^expected} =
               Interpreter.eval(bytecode.value, [], %{gas: 1_000_000}, bytecode.atoms)

      assert {:ok, ^expected} = VMCompiler.invoke(bytecode.value, [])
    end)
    |> Task.await(30_000)
  end

  defp assert_compiles_error_name(source, expected_name) do
    Task.async(fn ->
      Heap.reset()
      assert {:ok, bytecode} = JSCompiler.compile(source)

      assert {:error, {:js_throw, {:obj, interpreter_ref}}} =
               Interpreter.eval(bytecode.value, [], %{gas: 1_000_000}, bytecode.atoms)

      assert QuickBEAM.VM.ObjectModel.Get.get({:obj, interpreter_ref}, "name") == expected_name

      Heap.reset()
      assert {:ok, bytecode} = JSCompiler.compile(source)
      assert {:error, {:js_throw, {:obj, compiled_ref}}} = VMCompiler.invoke(bytecode.value, [])
      assert QuickBEAM.VM.ObjectModel.Get.get({:obj, compiled_ref}, "name") == expected_name
    end)
    |> Task.await(30_000)
  end
end
