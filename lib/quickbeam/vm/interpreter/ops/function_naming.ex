defmodule QuickBEAM.VM.Interpreter.Ops.FunctionNaming do
  @moduledoc "Function-name and home-object opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Names, ObjectModel.Functions}

      defp run({@op_set_name, [atom_idx]}, pc, frame, [fun | rest], gas, ctx) do
        named = Functions.set_name_atom(fun, atom_idx, ctx.atoms)
        run(pc + 1, frame, [named | rest], gas, ctx)
      end

      defp run({@op_set_name_computed, []}, pc, frame, [fun, name_val | rest], gas, ctx) do
        named = Functions.set_name_computed(fun, name_val)
        run(pc + 1, frame, [named, name_val | rest], gas, ctx)
      end

      defp run({@op_set_home_object, []}, pc, frame, [method, target | _] = stack, gas, ctx) do
        Functions.put_home_object(method, target)
        run(pc + 1, frame, stack, gas, ctx)
      end
    end
  end
end
