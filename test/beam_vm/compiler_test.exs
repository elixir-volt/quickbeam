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
