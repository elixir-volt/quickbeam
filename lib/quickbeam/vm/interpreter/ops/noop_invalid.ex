defmodule QuickBEAM.VM.Interpreter.Ops.NoopInvalid do
  @moduledoc "No-op and invalid-opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      defp run({@op_nop, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_invalid, []}, _pc, _frame, _stack, _gas, _ctx),
        do: throw({:error, :invalid_opcode})
    end
  end
end
