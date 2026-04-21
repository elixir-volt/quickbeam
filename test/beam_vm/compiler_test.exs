defmodule QuickBEAM.BeamVM.CompilerTest do
  use ExUnit.Case, async: true

  import QuickBEAM.BeamVM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.BeamVM.{Bytecode, Compiler, Heap, Interpreter}

  setup do
    Heap.reset()
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  defp compile_and_decode(rt, code) do
    {:ok, bc} = QuickBEAM.compile(rt, code)
    {:ok, parsed} = Bytecode.decode(bc)
    cache_function_atoms(parsed.value, parsed.atoms)
    parsed
  end

  defp cache_function_atoms(%Bytecode.Function{} = fun, atoms) do
    Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

    Enum.each(fun.constants, fn
      %Bytecode.Function{} = inner -> cache_function_atoms(inner, atoms)
      _ -> :ok
    end)
  end

  defp user_function(parsed) do
    case for %Bytecode.Function{} = fun <- parsed.value.constants, do: fun do
      [fun | _] -> fun
      [] -> parsed.value
    end
  end

  describe "compile/1" do
    test "compiles a straight-line arithmetic function", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){return a+b})") |> user_function()

      assert {:ok, {_mod, :run}} = Compiler.compile(fun)
      assert {:ok, 7} = Compiler.invoke(fun, [3, 4])
    end

    test "compiles locals and reassignment in straight-line code", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a){let x=1; x=x+a; return x})") |> user_function()

      assert {:ok, 6} = Compiler.invoke(fun, [5])
    end

    test "compiles conditional branches", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){if(x>0)return 1;else return 2})") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [3])
      assert {:ok, 2} = Compiler.invoke(fun, [-1])
    end

    test "compiles simple while loops", %{rt: rt} do
      code = "(function(n){let s=0; let i=0; while(i<n){ s=s+i; i=i+1;} return s})"
      fun = compile_and_decode(rt, code) |> user_function()

      assert {:ok, 10} = Compiler.invoke(fun, [5])
    end

    test "compiles loops over array length and array indexing", %{rt: rt} do
      code =
        "(function(arr){let s=0; let i=0; while(i<arr.length){ s=s+arr[i]; i=i+1;} return s})"

      fun = compile_and_decode(rt, code) |> user_function()

      assert {:ok, 10} = Compiler.invoke(fun, [Heap.wrap([1, 2, 3, 4])])
    end

    test "compiles object field access", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(obj){return obj.x})") |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles object creation plus field writes", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(v){ let o={}; o.x=v; return o.x })") |> user_function()

      assert {:ok, 9} = Compiler.invoke(fun, [9])
    end

    test "compiles object literals", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(v){ return {x:v} })") |> user_function()

      assert {:ok, {:obj, ref}} = Compiler.invoke(fun, [5])
      assert %{"x" => 5} = Heap.get_obj(ref)
    end

    test "compiles function calls through arguments", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(f,x){return f(x)})") |> user_function()
      callback = {:builtin, "double", fn [x], _ -> x * 2 end}

      assert {:ok, 8} = Compiler.invoke(fun, [callback, 4])
    end

    test "compiles method calls with receiver", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o,x){return o.inc(x)})") |> user_function()

      obj =
        Heap.wrap(%{
          "base" => 10,
          "inc" =>
            {:builtin, "inc",
             fn [x], this -> QuickBEAM.BeamVM.Runtime.Property.get(this, "base") + x end}
        })

      assert {:ok, 13} = Compiler.invoke(fun, [obj, 3])
    end

    test "compiles global lookup plus method call", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){return Math.abs(x)})") |> user_function()

      assert {:ok, 12} = Compiler.invoke(fun, [-12])
    end

    test "compiles array writes with indexed reads", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(v){ let a=[]; a[0]=v; return a[0] })")
        |> user_function()

      assert {:ok, 11} = Compiler.invoke(fun, [11])
    end

    test "compiles compound array updates", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,v){ a[0] += v; return a[0] })") |> user_function()

      assert {:ok, 8} = Compiler.invoke(fun, [Heap.wrap([3]), 5])
    end

    test "compiles loose-null checks before indexed writes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(i,v){ if (i == null) i = 0; let a=[]; a[i]=v; return a[i] })"
        )
        |> user_function()

      assert {:ok, 12} = Compiler.invoke(fun, [nil, 12])
      assert {:ok, 13} = Compiler.invoke(fun, [1, 13])
    end

    test "compiles local increments", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ x++; return x })") |> user_function()

      assert {:ok, 6} = Compiler.invoke(fun, [5])
    end

    test "compiles post-increment expression results", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return x++ })") |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [5])
    end

    test "compiles exponentiation", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){ return a ** b })") |> user_function()

      assert {:ok, 8.0} = Compiler.invoke(fun, [2, 3])
    end

    test "compiles bitwise operators", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(a,b){ return ((a & b) ^ 1) << 2 })") |> user_function()

      assert {:ok, 0} = Compiler.invoke(fun, [3, 1])
    end

    test "compiles modulo", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){ return a % b })") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [10, 3])
    end

    test "compiles logical not", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return !x })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [0])
      assert {:ok, false} = Compiler.invoke(fun, [1])
    end

    test "compiles bitwise not", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return ~x })") |> user_function()

      assert {:ok, -6} = Compiler.invoke(fun, [5])
    end

    test "compiles typeof", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return typeof x })") |> user_function()

      assert {:ok, "number"} = Compiler.invoke(fun, [5])
      assert {:ok, "undefined"} = Compiler.invoke(fun, [:undefined])
    end

    test "compiles specialized typeof comparisons", %{rt: rt} do
      function_fun =
        compile_and_decode(rt, "(function(x){ return typeof x === 'function' })")
        |> user_function()

      undefined_fun =
        compile_and_decode(rt, "(function(x){ return typeof x === 'undefined' })")
        |> user_function()

      assert {:ok, true} =
               Compiler.invoke(function_fun, [{:builtin, "noop", fn _, _ -> :undefined end}])

      assert {:ok, false} = Compiler.invoke(function_fun, [5])
      assert {:ok, true} = Compiler.invoke(undefined_fun, [:undefined])
      assert {:ok, true} = Compiler.invoke(undefined_fun, [nil])
      assert {:ok, false} = Compiler.invoke(undefined_fun, [0])
    end

    test "compiles null checks", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return x === null })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [nil])
      assert {:ok, false} = Compiler.invoke(fun, [:undefined])
    end

    test "compiles in operator", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(k,o){ return k in o })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, ["x", Heap.wrap(%{"x" => 1})])
      assert {:ok, false} = Compiler.invoke(fun, ["y", Heap.wrap(%{"x" => 1})])
    end

    test "compiles delete with atom property names", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ delete o.x; return o.x })") |> user_function()

      assert {:ok, :undefined} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles instanceof", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(obj, ctor){ return obj instanceof ctor })")
        |> user_function()

      parent_proto = Heap.wrap(%{})
      child = Heap.wrap(%{proto() => parent_proto})
      ctor = Heap.wrap(%{"prototype" => parent_proto})

      assert {:ok, true} = Compiler.invoke(fun, [child, ctor])
      assert {:ok, false} = Compiler.invoke(fun, [5, ctor])
    end

    test "compiles instanceof through prototype chains", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(obj, ctor){ return obj instanceof ctor })")
        |> user_function()

      parent_proto = Heap.wrap(%{})
      mid_proto = Heap.wrap(%{proto() => parent_proto})
      child = Heap.wrap(%{proto() => mid_proto})
      ctor = Heap.wrap(%{"prototype" => parent_proto})

      assert {:ok, true} = Compiler.invoke(fun, [child, ctor])
    end

    test "compiles constructor calls", %{rt: rt} do
      ctor = compile_and_decode(rt, "(function A(x){ this.x = x })") |> user_function()
      fun = compile_and_decode(rt, "(function(C,x){ return new C(x).x })") |> user_function()

      assert {:ok, 9} = Compiler.invoke(fun, [ctor, 9])
    end

    test "compiles constructor calls without arguments", %{rt: rt} do
      ctor = compile_and_decode(rt, "(function A(){ this.x = 1 })") |> user_function()
      fun = compile_and_decode(rt, "(function(C){ return new C().x })") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [ctor])
    end

    test "compiles array spread", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a){ return [...a].length })") |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [Heap.wrap([1, 2, 3])])
    end

    test "compiles object spread", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ return {...o}.x })") |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles object spread followed by field definition", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ return {...o, y:1}.y })") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles for-of loops over arrays", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(a){ let s=0; for (const x of a) s += x; return s })")
        |> user_function()

      assert {:ok, 10} = Compiler.invoke(fun, [Heap.wrap([1, 2, 3, 4])])
    end

    test "compiles for-of loops over strings", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(s){ let out=''; for (const ch of s) out += ch; return out })"
        )
        |> user_function()

      assert {:ok, "abc"} = Compiler.invoke(fun, ["abc"])
    end

    test "compiles try catch around explicit throws", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(e){ try { throw e } catch(err) { return err } })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [7])
    end

    test "compiles try catch around throwing calls", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(f){ try { return f() } catch(err) { return err } })")
        |> user_function()

      throwing_fun = {:builtin, "boom", fn [], _ -> throw({:js_throw, 11}) end}

      assert {:ok, 11} = Compiler.invoke(fun, [throwing_fun])
    end

    test "compiles nested try catch rethrows", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(f){ try { try { return f() } catch(err) { throw err } } catch(err) { return err } })"
        )
        |> user_function()

      throwing_fun = {:builtin, "boom", fn [], _ -> throw({:js_throw, 13}) end}

      assert {:ok, 13} = Compiler.invoke(fun, [throwing_fun])
    end

    test "compiles for-in loops over object keys", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(o){ let s=''; for (const k in o) s += k; return s })")
        |> user_function()

      assert {:ok, "ab"} = Compiler.invoke(fun, [Heap.wrap(%{"a" => 1, "b" => 2})])
    end

    test "compiles for-in loops over array indexes", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(a){ let s=''; for (const k in a) s += k; return s })")
        |> user_function()

      assert {:ok, "012"} = Compiler.invoke(fun, [Heap.wrap([10, 20, 30])])
    end

    test "compiles empty for-in fallthrough", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(o){ for (const k in o) return k; return 'none' })")
        |> user_function()

      assert {:ok, "none"} = Compiler.invoke(fun, [Heap.wrap(%{})])
    end

    test "compiles try finally with side effects", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ var x=0; try { x=1 } finally { x=2 } return x })")
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles try catch finally", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ var x=0; try { throw 'err' } catch(e) { x=1 } finally { x+=1 } return x })"
        )
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles try finally around returns", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(f){ try { return f() } finally { 1 } })")
        |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [{:builtin, "five", fn [], _ -> 5 end}])
    end

    test "compiles nested plain functions", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ function f(a,b){ return a+b } return f(1,2) })")
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles nested rest-parameter functions", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ function f(...args){ return args.length } return f(1,2,3) })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles nested default-parameter functions", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ function f(a,b=10){ return a+b } return f(5) })")
        |> user_function()

      assert {:ok, 15} = Compiler.invoke(fun, [])
    end

    test "compiles nested captured-argument functions", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){ function f(y){ return x+y } return f(2) })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [5])
    end

    test "compiles nested captured-local updates", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(x){ let y=x; function f(z){ return y+z } y=5; return f(2) })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [1])
    end

    test "compiles nested closures that mutate captured locals", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ let x=1; function f(){ x+=1; return x } return f()+f() })"
        )
        |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [])
    end

    test "compiles arrow closures with inferred names", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){ const f = (y) => x + y; return f(2) })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [5])
    end

    test "compiles object literal methods", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ return { m(){ return 1 } }.m() })")
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles object literal methods with captures", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){ return { m(y){ return x+y } }.m(2) })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [5])
    end

    test "compiles computed object literal methods", %{rt: rt} do
      fun =
        compile_and_decode(rt, ~s|(function(){ return ({ ["m"](){ return 1 } })["m"]() })|)
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles computed-name function expressions", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          ~s|(function(){ const n = "x"; return ({ [n]: function(){ return 1 } })[n]() })|
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles simple classes", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ class A { m(){ return 1 } } return new A().m() })")
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles classes with constructors", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { constructor(x){ this.x=x } } return new A(3).x })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles class inheritance with super methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { m(){ return 1 } } class B extends A { m(){ return super.m()+1 } } return new B().m() })"
        )
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles private field classes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 42; get() { return this.#x } } return new A().get() })"
        )
        |> user_function()

      assert {:ok, 42} = Compiler.invoke(fun, [])
    end

    test "compiles private field setters", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 0; set(v) { this.#x = v } get() { return this.#x } } var a = new A(); a.set(99); return a.get() })"
        )
        |> user_function()

      assert {:ok, 99} = Compiler.invoke(fun, [])
    end

    test "compiles private methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m() { return 3 } get() { return this.#m() } } return new A().get() })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles private accessors", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { get #x() { return 7 } read() { return this.#x } } return new A().read() })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [])
    end

    test "compiles private static fields", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 42; static get() { return A.#x } } return A.get() })"
        )
        |> user_function()

      assert {:ok, 42} = Compiler.invoke(fun, [])
    end

    test "compiles private static writes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static set(v){ A.#x = v } static get(){ return A.#x } } A.set(9); return A.get() })"
        )
        |> user_function()

      assert {:ok, 9} = Compiler.invoke(fun, [])
    end

    test "compiles private static methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #m(){ return 5 } static get(){ return A.#m() } } return A.get() })"
        )
        |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [])
    end

    test "compiles private static accessors", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static get #x(){ return 7 } static read(){ return A.#x } } return A.read() })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [])
    end

    test "compiles private static in checks", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static has(){ return #x in A } } return A.has() })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private field receivers", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; get(){ return this.#x } } const g = (new A()).get; try { return g.call({}) } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private method receivers", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m(){ return 1 } get(){ return this.#m() } } const g = (new A()).get; try { return g.call({}) } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private receivers across classes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; get(o){ try { return o.#x } catch (e) { return e instanceof TypeError } } } class B {} return new A().get(new B()) })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private static receivers across classes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static get(o){ try { return o.#x } catch (e) { return e instanceof TypeError } } } class B {} return A.get(B) })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private setters", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; set(v){ this.#x = v } } const s = (new A()).set; try { s.call({}, 2); return false } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "supports private members on subclass instances", %{rt: rt} do
      field_fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; get(){ return this.#x } } class B extends A {} return new B().get() })"
        )
        |> user_function()

      method_fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m(){ return 1 } call(){ return this.#m() } } class B extends A {} return new B().call() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(field_fun, [])
      assert {:ok, 1} = Compiler.invoke(method_fun, [])
    end

    test "rejects inherited private static access", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static get(){ return this.#x } } class B extends A {} try { return B.get() } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "inherits static methods named call", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static call(){ return 1 } } class B extends A {} return B.call() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "rejects inherited private static methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #m(){ return 1 } static call(){ return this.#m() } } class B extends A {} try { return B.call() } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "compiles private static blocks", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static { this.#x += 2 } static get(){ return this.#x } } return A.get() })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles private super calls", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m(){ return 1 } call(){ return this.#m() } } class B extends A { call2(){ return super.call() } } return new B().call2() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "preserves side-effectful dropped method calls", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ o.bump(); return o.n })") |> user_function()

      obj =
        Heap.wrap(%{
          "n" => 0,
          "bump" =>
            {:builtin, "bump",
             fn [], {:obj, ref} ->
               Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), "n", 1))
               :undefined
             end}
        })

      assert {:ok, 1} = Compiler.invoke(fun, [obj])
    end
  end

  describe "Interpreter integration" do
    test "eligible functions use the compiled cache", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(a,b){return a+b})")
      fun = user_function(parsed)

      assert 9 == Interpreter.invoke(fun, [4, 5], 1_000)
      assert {:compiled, {_mod, :run}} = Heap.get_compiled({fun.byte_code, fun.arg_count})
    end

    test "branchy functions also use the compiled cache", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(x){if(x>0)return 1;else return 2})")
      fun = user_function(parsed)

      assert 1 == Interpreter.invoke(fun, [5], 1_000)
      assert {:compiled, {_mod, :run}} = Heap.get_compiled({fun.byte_code, fun.arg_count})
    end
  end
end
