defmodule QuickBEAM.VM.Interpreter.Ops.SuperAccess do
  @moduledoc "Super-property opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Completion
      alias QuickBEAM.VM.Interpreter.Context
      alias QuickBEAM.VM.Interpreter.Ops.SuperProperties

      defp run({@op_get_super, []}, pc, frame, [func | rest], gas, %Context{} = ctx) do
        case Completion.capture(ctx, fn ->
               SuperProperties.get(func, ctx.home_object, ctx.super)
             end) do
          {:ok, value, ctx} -> run(pc + 1, frame, [value | rest], gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_get_super_value, []}, pc, frame, [key, proto, this_obj | rest], gas, ctx) do
        case Completion.capture(ctx, fn -> SuperProperties.get_value(proto, this_obj, key) end) do
          {:ok, value, ctx} -> run(pc + 1, frame, [value | rest], gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run(
             {@op_put_super_value, []},
             pc,
             frame,
             [val, key, proto_obj, this_obj | rest],
             gas,
             ctx
           ) do
        case Completion.capture(ctx, fn ->
               SuperProperties.put_value(proto_obj, this_obj, key, val)
             end) do
          {:ok, _value, ctx} -> run(pc + 1, frame, rest, gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
