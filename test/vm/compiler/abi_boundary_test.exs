defmodule QuickBEAM.VM.Compiler.ABIBoundaryTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{BytecodeParser, Compiler, Heap}
  alias QuickBEAM.VM.Compiler.RuntimeABI

  @allowed_extfunc_modules [RuntimeABI, :erlang, :maps]

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

  test "generated BEAM calls through the runtime ABI boundary", %{rt: rt} do
    snippets = [
      "var g=1; function f(obj){ obj.x = g; return obj.x + typeof missing } f({})",
      "(function(obj, arr, f){ let x = obj.a + arr[0]; obj.b=x; if ('a' in obj) x=f.call(obj,x); try{throw x}catch(e){ return typeof e + ':' + delete obj.c }})",
      "(function(C){ return new C(1).x })",
      "(function(){ return ({a:1, ['b']:2, get c(){return 3}}).c })",
      "(function(){ let i=0; while(i<3){ i++; } return i })",
      "(function(){ return (() => arguments.length)(1,2) })",
      "var abiGlobal = 1; abiGlobal = abiGlobal + 2; delete globalThis.abiMissing; abiGlobal",
      "var scope = {x: 1}; with (scope) { x = x + 1; } scope.x",
      "class Base { value(){ return 1 } } class Child extends Base { value(){ return super.value() + 1 } } new Child().value()"
    ]

    extfuncs =
      snippets
      |> Enum.flat_map(&compiled_functions(rt, &1))
      |> Enum.flat_map(&beam_extfuncs/1)
      |> Enum.uniq()

    forbidden =
      Enum.reject(extfuncs, fn {mod, _fun, _arity} -> mod in @allowed_extfunc_modules end)

    assert forbidden == []
  end

  defp compiled_functions(rt, code) do
    {:ok, bc} = QuickBEAM.compile(rt, code)
    {:ok, parsed} = BytecodeParser.decode(bc)
    cache_function_atoms(parsed.value, parsed.atoms)
    functions(parsed.value)
  end

  defp cache_function_atoms(%QuickBEAM.VM.Function{} = fun, atoms) do
    Heap.put_fn_atoms(fun, atoms)

    Enum.each(fun.constants, fn
      %QuickBEAM.VM.Function{} = inner -> cache_function_atoms(inner, atoms)
      _ -> :ok
    end)
  end

  defp functions(%QuickBEAM.VM.Function{} = fun) do
    nested =
      Enum.flat_map(fun.constants, fn
        %QuickBEAM.VM.Function{} = inner -> functions(inner)
        _ -> []
      end)

    [fun | nested]
  end

  defp beam_extfuncs(%QuickBEAM.VM.Function{} = fun) do
    case Compiler.disasm(fun) do
      {:ok, beam_file} -> beam_file_extfuncs(beam_file)
      {:error, _} -> []
    end
  end

  defp beam_file_extfuncs({:beam_file, _module, _exports, _attributes, _compile_info, code}) do
    for {:function, _name, _arity, _label, instructions} <- code,
        {op, _argc, {:extfunc, mod, fun, arity}} <- instructions,
        op in [:call_ext, :call_ext_last, :call_ext_only] do
      {mod, fun, arity}
    end
  end
end
