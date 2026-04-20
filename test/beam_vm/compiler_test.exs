defmodule QuickBEAM.BeamVM.CompilerTest do
  use ExUnit.Case, async: true

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
