defmodule QuickBEAM.VM.Interpreter.Ops.TypePredicates do
  @moduledoc "Type predicate opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Builtin, Value}

      defp run({@op_is_undefined, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [a == :undefined | rest], gas, ctx)

      defp run({@op_is_null, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [a == nil | rest], gas, ctx)

      defp run({@op_is_undefined_or_null, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [Value.nullish?(a) | rest], gas, ctx)

      defp run({@op_typeof_is_function, []}, pc, frame, [val | rest], gas, ctx) do
        run(pc + 1, frame, [Builtin.callable?(val) | rest], gas, ctx)
      end

      defp run({@op_typeof_is_undefined, []}, pc, frame, [val | rest], gas, ctx) do
        run(pc + 1, frame, [Value.nullish?(val) | rest], gas, ctx)
      end
    end
  end
end
