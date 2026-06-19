defmodule QuickBEAM.VM.Interpreter.Ops.DeleteProperty do
  @moduledoc "delete-property opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      import QuickBEAM.VM.Value, only: [is_nullish: 1]
      alias QuickBEAM.VM.Heap
      alias QuickBEAM.VM.Interpreter.Ops.Delete, as: DeleteOp

      defp run({@op_delete, []}, __pc, frame, [key, obj | _rest], gas, ctx)
           when is_nullish(obj) do
        throw_or_catch(frame, DeleteOp.nullish_error(obj, key), gas, ctx)
      end

      defp run({@op_delete, []}, pc, frame, [key, obj | rest], gas, ctx) do
        result = DeleteOp.property(obj, key)

        if result == false and current_strict_mode?(ctx) do
          throw_or_catch(frame, Heap.make_error("Cannot delete property", "TypeError"), gas, ctx)
        else
          run(pc + 1, frame, [result | rest], gas, ctx)
        end
      end
    end
  end
end
