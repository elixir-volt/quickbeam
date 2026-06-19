defmodule QuickBEAM.VM.Interpreter.Ops.ThrowErrors do
  @moduledoc "Throw-error opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, Names}
      alias QuickBEAM.VM.Semantics.ThrowErrors

      defp run({@op_throw_error, []}, _pc, frame, [val | _], gas, ctx),
        do: throw_or_catch(frame, val, gas, ctx)

      defp run({@op_throw_error, [atom_idx, reason]}, __pc, frame, _stack, gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)
        {error_type, message} = ThrowErrors.message(name, reason)
        throw_or_catch(frame, Heap.make_error(message, error_type), gas, ctx)
      end
    end
  end
end
