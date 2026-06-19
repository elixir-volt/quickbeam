defmodule QuickBEAM.VM.Interpreter.Ops.InOperatorAdapter do
  @moduledoc "in-operator opcode handler."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Ops.InOperator

      defp run({@op_in, []}, pc, frame, [obj, key | rest], gas, ctx) do
        persistent_before = QuickBEAM.VM.Heap.get_persistent_globals()
        QuickBEAM.VM.RuntimeState.install(ctx)

        call_result =
          try do
            {:ok, InOperator.evaluate(key, obj)}
          catch
            {:js_throw, val} -> {:throw, val}
          end

        case call_result do
          {:ok, result} ->
            ctx = refresh_persistent_globals(ctx)

            frame =
              if QuickBEAM.VM.Heap.get_persistent_globals() != persistent_before do
                sync_global_writes_to_frame(frame, QuickBEAM.VM.RuntimeState.current_or(ctx))
              else
                frame
              end

            run(pc + 1, frame, [result | rest], gas, ctx)

          {:throw, val} ->
            throw_or_catch(frame, val, gas, close_active_iterators_on_abrupt(rest, ctx))
        end
      end
    end
  end
end
