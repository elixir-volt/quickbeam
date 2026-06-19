defmodule QuickBEAM.VM.Interpreter.Ops.PrivateSymbols do
  @moduledoc "Private-symbol opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Names
      alias QuickBEAM.VM.Interpreter.Ops.PrivateFields

      defp run({@op_private_symbol, [atom_idx]}, pc, frame, stack, gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)
        run(pc + 1, frame, [PrivateFields.symbol(name) | stack], gas, ctx)
      end
    end
  end
end
