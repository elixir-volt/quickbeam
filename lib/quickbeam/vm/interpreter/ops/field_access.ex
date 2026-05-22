defmodule QuickBEAM.VM.Interpreter.Ops.FieldAccess do
  @moduledoc "Object field and property-key opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      import QuickBEAM.VM.Value, only: [is_nullish: 1]

      alias QuickBEAM.VM.{Heap, Names, RuntimeState}
      alias QuickBEAM.VM.ObjectModel.{Get, Put}
      alias QuickBEAM.VM.Semantics.PropertyAccess
      alias QuickBEAM.VM.Interpreter.Ops.PropertyKeys

      defp run({@op_get_field, [atom_idx]}, __pc, frame, [obj | _rest], gas, ctx)
           when is_nullish(obj) do
        throw_null_property_error(frame, obj, atom_idx, gas, ctx)
      end

      defp run({@op_get_field, [atom_idx]}, pc, frame, [obj | rest], gas, ctx) do
        run(pc + 1, frame, [Get.get(obj, Names.resolve_atom(ctx, atom_idx)) | rest], gas, ctx)
      end

      defp run({@op_put_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
        name = Names.resolve_atom(ctx, atom_idx)

        result =
          try do
            PropertyAccess.set_property(ctx, obj, name, val)
            :ok
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          :ok ->
            ctx =
              if QuickBEAM.VM.Execution.SetterState.invoked?(),
                do: ctx,
                else: sync_global_this_write(ctx, obj, name, val)

            ctx = refresh_persistent_globals(ctx)
            frame = sync_setter_globals_to_frame(frame, ctx)
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, close_active_iterators_on_abrupt(rest, ctx))
        end
      end

      defp run({@op_define_field, [atom_idx]}, pc, frame, [val, obj | rest], gas, ctx) do
        try do
          Put.define_array_el(obj, Names.resolve_atom(ctx, atom_idx), val)
          run(pc + 1, frame, [obj | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = RuntimeState.current_or(ctx)
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_get_field2, [atom_idx]}, __pc, frame, [obj | _rest], gas, ctx)
           when is_nullish(obj) do
        throw_null_property_error(frame, obj, atom_idx, gas, ctx)
      end

      defp run({@op_get_field2, [atom_idx]}, pc, frame, [obj | rest], gas, ctx) do
        val = Get.get(obj, Names.resolve_atom(ctx, atom_idx))
        run(pc + 1, frame, [val, obj | rest], gas, ctx)
      end

      defp run({@op_get_length, []}, pc, frame, [obj | rest], gas, ctx) do
        run(pc + 1, frame, [Get.length_of(obj) | rest], gas, ctx)
      end

      defp run({@op_to_propkey, []}, pc, frame, [key | rest], gas, ctx) do
        case PropertyKeys.to_property_key(key, ctx) do
          {:ok, prop_key, ctx} -> run(pc + 1, frame, [prop_key | rest], gas, ctx)
          {:throw, error, ctx} -> throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_to_propkey2, []}, pc, frame, [key, obj | rest], gas, ctx) do
        try do
          prop_key = PropertyAccess.to_property_key_for_access(obj, key)

          run(
            pc + 1,
            frame,
            [prop_key, obj | rest],
            gas,
            RuntimeState.refresh_globals(ctx)
          )
        catch
          {:js_throw, error} -> throw_or_catch(frame, error, gas, RuntimeState.current_or(ctx))
        end
      end
    end
  end
end
