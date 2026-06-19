defmodule QuickBEAM.VM.Interpreter.Ops.DeleteVars do
  @moduledoc "Variable-delete opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, Names}

      @non_configurable_globals MapSet.new(~w(NaN undefined Infinity globalThis))

      defp run({@op_delete_var, [atom_idx]}, pc, frame, stack, gas, ctx) do
        name = Names.resolve_atom(ctx.atoms, atom_idx)
        builtins = Heap.get_builtin_names() || MapSet.new()

        result =
          case Map.fetch(ctx.globals, name) do
            {:ok, _} ->
              if MapSet.member?(@non_configurable_globals, name) do
                false
              else
                MapSet.member?(builtins, name)
              end

            :error ->
              true
          end

        run(pc + 1, frame, [result | stack], gas, ctx)
      end
    end
  end
end
