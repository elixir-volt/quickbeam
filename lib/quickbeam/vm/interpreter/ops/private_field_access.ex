defmodule QuickBEAM.VM.Interpreter.Ops.PrivateFieldAccess do
  @moduledoc "Private-field access opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Ops.PrivateFields

      defp run({@op_get_private_field, []}, pc, frame, [key, obj | rest], gas, ctx) do
        case PrivateFields.get(obj, key) do
          {:ok, val} -> run(pc + 1, frame, [val | rest], gas, ctx)
          {:throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_put_private_field, []}, pc, frame, [key, val, obj | rest], gas, ctx) do
        case PrivateFields.put(obj, key, val) do
          :ok -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_define_private_field, []}, pc, frame, [val, key, obj | rest], gas, ctx) do
        case PrivateFields.define(obj, key, val) do
          :ok -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_private_in, []}, pc, frame, [key, obj | rest], gas, ctx) do
        run(pc + 1, frame, [PrivateFields.has?(obj, key) | rest], gas, ctx)
      end
    end
  end
end
