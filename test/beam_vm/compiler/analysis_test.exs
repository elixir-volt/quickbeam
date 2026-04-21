defmodule QuickBEAM.BeamVM.Compiler.AnalysisTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.BeamVM.{Bytecode, Compiler.Analysis, Decoder, Heap}

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

  defp compile_parsed(rt, code) do
    {:ok, bc} = QuickBEAM.compile(rt, code)
    {:ok, parsed} = Bytecode.decode(bc)
    parsed
  end

  defp compile_function(rt, code) do
    parsed = compile_parsed(rt, code)

    case for %Bytecode.Function{} = fun <- parsed.value.constants, do: fun do
      [fun | _] -> fun
      [] -> parsed.value
    end
  end

  defp infer_types(fun) do
    {:ok, instructions} = Decoder.decode(fun.byte_code, fun.arg_count)
    entries = Analysis.block_entries(instructions)
    {:ok, stack_depths} = Analysis.infer_block_stack_depths(instructions, entries)

    {:ok, {entry_types, return_type}} =
      Analysis.infer_block_entry_types(fun, instructions, entries, stack_depths)

    {entry_types, return_type}
  end

  test "infers recursive self-call return type from literal base cases", %{rt: rt} do
    fun = compile_function(rt, "(function f(n){ return n ? f(n - 1) : 0 })")

    {_entry_types, return_type} = infer_types(fun)

    assert return_type == :integer
  end

  test "propagates numeric local types across loop backedges", %{rt: rt} do
    fun =
      compile_function(rt, "(function(n){let s=0; let i=0; while(i<n){ s=s+i; i=i+1;} return s})")

    {entry_types, return_type} = infer_types(fun)

    loop_state = Map.fetch!(entry_types, 6)

    assert loop_state.slot_types[1] == :integer
    assert loop_state.slot_types[2] == :integer
    assert return_type == :integer
  end

  test "tracks return types for nested local functions", %{rt: rt} do
    parsed =
      compile_parsed(rt, "(function(){ function f(){ return 1 } let x = f(); return x + 1 })")

    [outer] = for %Bytecode.Function{} = fun <- parsed.value.constants, do: fun
    [inner] = for %Bytecode.Function{} = fun <- outer.constants, do: fun

    {_inner_entry_types, inner_return_type} = infer_types(inner)
    {_outer_entry_types, outer_return_type} = infer_types(outer)

    assert Analysis.function_type(inner) == {:function, :integer}
    assert inner_return_type == :integer
    assert outer_return_type == :integer
  end
end
