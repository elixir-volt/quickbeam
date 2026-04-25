defmodule QuickBEAM.VM.Interpreter.Ops.Generators do
  @moduledoc "Generator yield, yield_star, await, initial_yield, and return_async opcodes."

  defmacro __using__(_opts) do
    quote location: :keep do
      # ── Generators ──

      defp run({@op_initial_yield, []}, pc, frame, stack, gas, ctx) do
        throw({:generator_yield, :undefined, pc + 1, frame, stack, gas, ctx})
      end

      defp run({@op_yield, []}, pc, frame, [val | rest], gas, ctx) do
        throw({:generator_yield, val, pc + 1, frame, rest, gas, ctx})
      end

      defp run({@op_yield_star, []}, pc, frame, [val | rest], gas, ctx) do
        throw({:generator_yield_star, val, pc + 1, frame, rest, gas, ctx})
      end

      defp run({@op_async_yield_star, []}, pc, frame, [val | rest], gas, ctx) do
        throw({:generator_yield_star, val, pc + 1, frame, rest, gas, ctx})
      end

      defp run({@op_await, []}, pc, frame, [val | rest], gas, ctx) do
        resolved = resolve_awaited(val)
        run(pc + 1, frame, [resolved | rest], gas, ctx)
      end

      defp run({@op_return_async, []}, _pc, _frame, [val | _], _gas, _ctx) do
        throw({:generator_return, val})
      end
    end
  end
end
