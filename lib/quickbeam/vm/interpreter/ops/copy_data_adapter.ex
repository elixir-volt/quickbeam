defmodule QuickBEAM.VM.Interpreter.Ops.CopyDataAdapter do
  @moduledoc "copy_data_properties opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Ops.CopyDataProperties, as: CopyOp

      defp run({@op_copy_data_properties, []}, pc, frame, [source, target | rest], gas, ctx) do
        case CopyOp.copy(target, source, ctx) do
          {:ok, ctx} -> run(pc + 1, frame, [source, target | rest], gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_copy_data_properties, [mask]}, pc, frame, stack, gas, ctx) do
        case CopyOp.copy_masked(stack, mask, ctx) do
          {:ok, ctx} -> run(pc + 1, frame, stack, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
