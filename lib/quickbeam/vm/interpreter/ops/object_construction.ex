defmodule QuickBEAM.VM.Interpreter.Ops.ObjectConstruction do
  @moduledoc "Object construction and basic conversion opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Heap
      alias QuickBEAM.VM.Interpreter.Context
      alias QuickBEAM.VM.Interpreter.Ops.SpecialObjects
      alias QuickBEAM.VM.Semantics.Construction

      defp run({@op_object, []}, pc, frame, stack, gas, ctx) do
        run(pc + 1, frame, [Construction.new_object() | stack], gas, ctx)
      end

      defp run({@op_regexp, []}, pc, frame, [pattern, flags | rest], gas, ctx) do
        run(pc + 1, frame, [{:regexp, pattern, flags, make_ref()} | rest], gas, ctx)
      end

      defp run({@op_special_object, [type]}, pc, frame, stack, gas, %Context{} = ctx) do
        {val, ctx} = SpecialObjects.build(type, frame, ctx)
        run(pc + 1, frame, [val | stack], gas, ctx)
      end

      defp run({@op_to_object, []}, _pc, frame, [nil | _rest], gas, ctx) do
        throw_or_catch(
          frame,
          Heap.make_error("Cannot convert null to object", "TypeError"),
          gas,
          ctx
        )
      end

      defp run({@op_to_object, []}, _pc, frame, [:undefined | _rest], gas, ctx) do
        throw_or_catch(
          frame,
          Heap.make_error("Cannot convert undefined to object", "TypeError"),
          gas,
          ctx
        )
      end

      defp run({@op_to_object, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)
    end
  end
end
