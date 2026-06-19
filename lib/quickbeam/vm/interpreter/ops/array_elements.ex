defmodule QuickBEAM.VM.Interpreter.Ops.ArrayElements do
  @moduledoc "Array element and array construction opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Completion
      alias QuickBEAM.VM.Interpreter.Ops.ObjectLiterals
      alias QuickBEAM.VM.Semantics.PropertyAccess

      defp run({@op_array_from, [argc]}, pc, frame, stack, gas, ctx) do
        {elems, rest} = Enum.split(stack, argc)
        values = Enum.reverse(elems)
        run(pc + 1, frame, [ObjectLiterals.array_from(values) | rest], gas, ctx)
      end

      defp run({@op_get_array_el, []}, pc, frame, [idx, obj | rest], gas, ctx) do
        try do
          run(pc + 1, frame, [PropertyAccess.get_property(obj, idx) | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            throw_or_catch(frame, error, gas, Completion.current_context(ctx))
        end
      end

      defp run({@op_put_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
        try do
          PropertyAccess.set_property(ctx, obj, idx, val)

          ctx = Completion.refresh_persistent_globals(ctx)

          frame = sync_setter_globals_to_frame(frame, ctx)
          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            throw_or_catch(
              frame,
              error,
              gas,
              rest |> close_active_iterators_on_abrupt(Completion.current_context(ctx))
            )
        end
      end

      defp run({@op_get_array_el2, []}, pc, frame, [idx, obj | rest], gas, ctx) do
        try do
          run(pc + 1, frame, [PropertyAccess.get_property(obj, idx), obj | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            throw_or_catch(frame, error, gas, Completion.current_context(ctx))
        end
      end
    end
  end
end
