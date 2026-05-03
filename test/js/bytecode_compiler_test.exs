defmodule QuickBEAM.JS.BytecodeCompilerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.BytecodeCompiler
  alias QuickBEAM.VM.{Compiler, Heap, Interpreter}

  describe "compile/1" do
    test "compiles arithmetic expression scripts" do
      assert_compiles_to("1 + 2 * 3", 7)
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
      assert_compiles_to("let x = 1; ({x}).x", 1)
      assert_compiles_to("let {x} = {x: 9}; x", 9)
      assert_compiles_to("let {x, y} = {x: 2, y: 3}; x + y", 5)
      assert_compiles_to("let k = \"x\"; ({[k]: 2}).x", 2)
      assert_compiles_to("({[1]: 2})[1]", 2)
    end

    test "compiles generic calls and for loops" do
      assert_compiles_to("function f(a,b,c,d){ return a+b+c+d; } f(1,2,3,4)", 10)
      assert_compiles_to("let s=0; for(let i=0; i<4; i=i+1){ s=s+i; } s", 6)
    end

    test "compiles loop break and continue" do
      assert_compiles_to("let x=0; while (x < 5) { x=x+1; break; } x", 1)
      assert_compiles_to("let x=0; let y=0; while (x < 3) { x=x+1; continue; y=9; } x+y", 3)
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
      assert_compiles_to("function make(x){ return function(y){ return x + y; }; } make(2)(3)", 5)

      assert_compiles_to(
        "function make(){ let x = 2; return function(y){ return x + y; }; } make()(3)",
        5
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

    test "emits QuickJS-loadable bytecode binaries" do
      assert {:ok, binary} =
               BytecodeCompiler.compile_to_binary("function f(a){ return a + 1; } f(2)")

      assert {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        assert {:ok, 3} = QuickBEAM.load_bytecode(rt, binary)
      after
        QuickBEAM.stop(rt)
      end
    end

    test "keeps the new frontend compiler separate from the VM compiler" do
      assert {:ok, bytecode} = BytecodeCompiler.compile("1 + 2")
      assert %QuickBEAM.VM.Bytecode{} = bytecode
      assert {:ok, 3} = Compiler.invoke(bytecode.value, [])
    end

    test "rewrites simple native QuickJS bytecode binaries" do
      assert {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        assert {:ok, native} = QuickBEAM.compile(rt, "function f(a){ return a + 1; } f(2)")
        assert {:ok, decoded} = QuickBEAM.VM.Bytecode.decode(native)
        assert {:ok, encoded} = QuickBEAM.VM.Bytecode.Writer.encode(decoded)
        assert {:ok, 3} = QuickBEAM.load_bytecode(rt, encoded)
      after
        QuickBEAM.stop(rt)
      end
    end

    test "returns an explicit unsupported error for unresolved globals" do
      assert {:error, {:unsupported, {:unresolved_identifier, "missing"}}} =
               BytecodeCompiler.compile("missing")
    end
  end

  defp assert_compiles_to(source, expected) do
    Task.async(fn ->
      Heap.reset()
      assert {:ok, bytecode} = BytecodeCompiler.compile(source)

      assert {:ok, ^expected} =
               Interpreter.eval(bytecode.value, [], %{gas: 1_000_000}, bytecode.atoms)

      assert {:ok, ^expected} = Compiler.invoke(bytecode.value, [])
    end)
    |> Task.await(30_000)
  end
end
