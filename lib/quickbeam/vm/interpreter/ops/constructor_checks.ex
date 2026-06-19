defmodule QuickBEAM.VM.Interpreter.Ops.ConstructorChecks do
  @moduledoc "Constructor result-check opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Heap
      alias QuickBEAM.VM.Semantics.Construction

      defp run({@op_check_ctor, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_check_ctor_return, []}, pc, frame, [val | rest], gas, ctx) do
        case Construction.check_ctor_return(val) do
          {:ok, replace_with_this?, checked_val} ->
            run(pc + 1, frame, [replace_with_this?, checked_val | rest], gas, ctx)

          {:error, message} ->
            throw_or_catch(frame, Heap.make_error(message, "TypeError"), gas, ctx)
        end
      end
    end
  end
end
