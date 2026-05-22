defmodule QuickBEAM.VM.Interpreter.Ops.SuperAccess do
  @moduledoc "Super-property opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Context
      alias QuickBEAM.VM.Interpreter.Ops.SuperProperties
      alias QuickBEAM.VM.RuntimeState

      defp run({@op_get_super, []}, pc, frame, [func | rest], gas, %Context{} = ctx) do
        val = SuperProperties.get(func, ctx.home_object, ctx.super)
        run(pc + 1, frame, [val | rest], gas, ctx)
      end

      defp run({@op_get_super_value, []}, pc, frame, [key, proto, this_obj | rest], gas, ctx) do
        val = SuperProperties.get_value(proto, this_obj, key)
        run(pc + 1, frame, [val | rest], gas, ctx)
      end

      defp run(
             {@op_put_super_value, []},
             pc,
             frame,
             [val, key, proto_obj, this_obj | rest],
             gas,
             ctx
           ) do
        try do
          SuperProperties.put_value(proto_obj, this_obj, key, val)
          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current_or(ctx)
            throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
