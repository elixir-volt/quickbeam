defmodule QuickBEAM.VM.Interpreter.Ops.InstanceOfAdapter do
  @moduledoc "instanceof opcode handler."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Ops.InstanceOf

      defp run({@op_instanceof, []}, pc, frame, [ctor, obj | rest], gas, ctx) do
        catch_and_dispatch(
          pc,
          frame,
          rest,
          gas,
          ctx,
          fn -> InstanceOf.evaluate(obj, ctor) end,
          true
        )
      end
    end
  end
end
