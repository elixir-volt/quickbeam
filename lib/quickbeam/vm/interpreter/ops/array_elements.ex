defmodule QuickBEAM.VM.Interpreter.Ops.ArrayElements do
  @moduledoc "Array element and array construction opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, RuntimeState}
      alias QuickBEAM.VM.Interpreter.Context
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
            ctx = RuntimeState.current_or(ctx)
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_put_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
        try do
          PropertyAccess.set_property(ctx, obj, idx, val)

          ctx =
            case Heap.get_persistent_globals() do
              nil -> ctx
              p when map_size(p) == 0 -> ctx
              p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
            end

          frame = sync_setter_globals_to_frame(frame, ctx)
          run(pc + 1, frame, rest, gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current_or(ctx)
            throw_or_catch(frame, error, gas, close_active_iterators_on_abrupt(rest, ctx))
        end
      end

      defp run({@op_get_array_el2, []}, pc, frame, [idx, obj | rest], gas, ctx) do
        try do
          run(pc + 1, frame, [PropertyAccess.get_property(obj, idx), obj | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current_or(ctx)
            throw_or_catch(frame, error, gas, ctx)
        end
      end
    end
  end
end
