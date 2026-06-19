defmodule QuickBEAM.VM.Interpreter.Ops.ThisValue do
  @moduledoc "this-value opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      import QuickBEAM.VM.Value, only: [is_nullish: 1]
      alias QuickBEAM.VM.{Function, Heap}
      alias QuickBEAM.VM.Interpreter.Context

      defp run({@op_push_this, []}, _pc, frame, _stack, gas, %Context{this: this} = ctx)
           when this == :uninitialized or
                  (is_tuple(this) and tuple_size(this) == 2 and elem(this, 0) == :uninitialized) do
        throw_or_catch(
          frame,
          Heap.make_error("this is not initialized", "ReferenceError"),
          gas,
          ctx
        )
      end

      defp run(
             {@op_push_this, []},
             pc,
             frame,
             stack,
             gas,
             %Context{this: this, current_func: %Function{is_strict_mode: true}} = ctx
           )
           when this in [:undefined, nil] do
        run(pc + 1, frame, [this | stack], gas, ctx)
      end

      defp run(
             {@op_push_this, []},
             pc,
             frame,
             stack,
             gas,
             %Context{this: this, current_func: {:closure, _, %Function{is_strict_mode: true}}} =
               ctx
           )
           when this in [:undefined, nil] do
        run(pc + 1, frame, [this | stack], gas, ctx)
      end

      defp run({@op_push_this, []}, pc, frame, stack, gas, %Context{this: this} = ctx)
           when is_nullish(this) do
        global_this = Map.get(ctx.globals, "globalThis", :undefined)
        run(pc + 1, frame, [global_this | stack], gas, ctx)
      end

      defp run({@op_push_this, []}, pc, frame, stack, gas, %Context{this: this} = ctx) do
        run(pc + 1, frame, [this | stack], gas, ctx)
      end
    end
  end
end
