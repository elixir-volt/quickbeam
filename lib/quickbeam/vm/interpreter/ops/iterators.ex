defmodule QuickBEAM.VM.Interpreter.Ops.Iterators do
  @moduledoc "For-in, for-of, iterator_*, spread, and array construction opcodes."

  @doc "Installs the For-in, for-of, iterator_*, spread, and array construction opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, Invocation, Runtime, RuntimeState}
      alias QuickBEAM.VM.Interpreter.Completion
      alias QuickBEAM.VM.ObjectModel.{Copy, Get, Put}
      alias QuickBEAM.VM.Semantics.Iterators

      # ── for-in ──

      defp run({@op_for_in_start, []}, _pc, frame, [obj | _rest], gas, ctx)
           when obj == :uninitialized do
        throw_or_catch(
          frame,
          Heap.make_error("this is not initialized", "ReferenceError"),
          gas,
          ctx
        )
      end

      defp run({@op_for_in_start, []}, pc, frame, [obj | rest], gas, ctx) do
        run(pc + 1, frame, [Iterators.for_in_start(ctx, obj) | rest], gas, ctx)
      end

      defp run({@op_for_in_next, []}, pc, frame, [iter | rest], gas, ctx) do
        {done?, key, next_iter} = Iterators.for_in_next(ctx, iter)
        run(pc + 1, frame, [done?, key, next_iter | rest], gas, ctx)
      end

      # ── spread / array construction ──

      defp run({@op_append, []}, pc, frame, [obj, idx, arr | rest], gas, ctx) do
        src_list = Copy.spread_source_to_list(obj)

        arr_list =
          case arr do
            {:qb_arr, arr_data} -> :array.to_list(arr_data)
            list when is_list(list) -> list
            {:obj, ref} -> Heap.to_list({:obj, ref})
            _ -> []
          end

        merged = arr_list ++ src_list
        new_idx = if(is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)

        merged_obj =
          case arr do
            {:obj, ref} ->
              Heap.put_obj(ref, merged)
              {:obj, ref}

            _ ->
              merged
          end

        run(pc + 1, frame, [new_idx, merged_obj | rest], gas, ctx)
      end

      defp run({@op_define_array_el, []}, pc, frame, [val, idx, obj | rest], gas, ctx) do
        try do
          idx = QuickBEAM.VM.ObjectModel.PropertyKey.to_property_key(idx)
          ctx = Completion.refresh_globals(ctx)
          val = resolve_delayed_define_value(val, ctx)
          {_idx, obj2} = Put.define_array_el(obj, idx, val)
          run(pc + 1, frame, [idx, obj2 | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            throw_or_catch(frame, error, gas, Completion.current_context(ctx))
        end
      end

      # ── Iterators ──

      defp run({@op_for_of_start, []}, pc, frame, [obj | rest], gas, ctx) do
        result =
          try do
            {:ok, Iterators.for_of_start(ctx, obj)}
          catch
            {:js_throw, val} -> {:throw, val}
          end

        case result do
          {:ok, {iter_obj, next_fn}} ->
            run(pc + 1, frame, [0, next_fn, iter_obj | rest], gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_for_of_next, [idx]}, pc, frame, stack, gas, ctx) do
        offset = 3 + idx
        iter_obj = Enum.at(stack, offset - 1)
        next_fn = Enum.at(stack, offset - 2)

        result =
          try do
            {:ok, Iterators.for_of_next(ctx, next_fn, iter_obj)}
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          {:ok, {done?, value, next_iter}} ->
            ctx = Completion.refresh_persistent_globals(ctx)
            updated_stack = List.replace_at(stack, offset - 1, next_iter)

            if done? do
              run(pc + 1, frame, [true, :undefined | updated_stack], gas, ctx)
            else
              run(pc + 1, frame, [false, value | updated_stack], gas, ctx)
            end

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run(
             {@op_iterator_next, []},
             pc,
             frame,
             [val, catch_offset, next_fn, iter_obj | rest],
             gas,
             ctx
           ) do
        result =
          try do
            {:ok, Iterators.iterator_next_result(ctx, next_fn, iter_obj, val)}
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          {:ok, {result, next_iter}} ->
            RuntimeState.put_iterator_result_owner(result, iter_obj)
            ctx = Completion.refresh_persistent_globals(ctx)
            run(pc + 1, frame, [result, catch_offset, next_fn, next_iter | rest], gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_iterator_get_value_done, []}, pc, frame, [result | rest], gas, ctx) do
        case Completion.capture(ctx, fn -> iterator_value_done_stack(result, rest) end) do
          {:ok, stack, ctx} ->
            run(pc + 1, frame, stack, gas, ctx)

          {:throw, error, ctx} ->
            close_iterator_result_owner(result, ctx)
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp iterator_value_done_stack(result, rest) do
        done = Get.get(result, "done")

        if Runtime.truthy?(done) do
          [true, :undefined | rest]
        else
          [false, Get.get(result, "value") | rest]
        end
      end

      defp close_iterator_result_owner(result, ctx) do
        case RuntimeState.get_iterator_result_owner(result) do
          nil ->
            :ok

          iter_obj ->
            try do
              Iterators.iterator_close(ctx, iter_obj)
            catch
              {:js_throw, _error} -> :ok
            end
        end
      end

      defp run(
             {@op_iterator_close, []},
             pc,
             frame,
             [_catch_offset, _next_fn, iter_obj | rest],
             gas,
             ctx
           ) do
        result =
          try do
            Iterators.iterator_close(ctx, iter_obj)
            {:ok, Completion.current_context(ctx)}
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          {:ok, ctx} ->
            run(pc + 1, frame, rest, gas, Completion.refresh_persistent_globals(ctx))

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_iterator_check_object, []}, pc, frame, [value | _] = stack, gas, ctx) do
        if Iterators.iterator_result_object?(value) do
          run(pc + 1, frame, stack, gas, ctx)
        else
          throw_or_catch(
            frame,
            Heap.make_error("iterator result is not an object", "TypeError"),
            gas,
            ctx
          )
        end
      end

      defp run({@op_iterator_call, [flags]}, pc, frame, stack, gas, ctx) do
        [val, catch_offset, next_fn, iter_obj | rest] = stack

        result =
          try do
            {:ok,
             Iterators.iterator_call(
               ctx,
               flags,
               val,
               catch_offset,
               next_fn,
               iter_obj
             )}
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          {:ok, {missing?, value, catch_offset, next_fn, iter_obj}} ->
            run(
              pc + 1,
              frame,
              [missing?, value, catch_offset, next_fn, iter_obj | rest],
              gas,
              ctx
            )

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_iterator_call, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      # ── for-await-of ──

      defp run({@op_for_await_of_start, []}, pc, frame, [obj | rest], gas, ctx) do
        sym_async_iter = {:symbol, "Symbol.asyncIterator"}
        sym_iter = {:symbol, "Symbol.iterator"}

        case Completion.capture(ctx, fn -> for_await_start_pair(obj, sym_async_iter, sym_iter) end) do
          {:ok, {iter_obj, next_fn}, ctx} ->
            run(pc + 1, frame, [0, next_fn, iter_obj | rest], gas, ctx)

          {:throw, error, ctx} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp for_await_start_pair({:obj, ref} = obj, sym_async_iter, sym_iter) do
        stored = Heap.get_obj(ref, [])

        cond do
          match?({:qb_arr, _}, stored) ->
            make_list_iterator(Heap.to_list({:obj, ref}))

          is_list(stored) ->
            make_list_iterator(stored)

          is_map(stored) and Map.has_key?(stored, sym_async_iter) ->
            async_iter_fn = Map.get(stored, sym_async_iter)
            iter = Invocation.invoke_callback_or_throw(async_iter_fn, [], obj)
            {iter, Get.get(iter, "next")}

          is_map(stored) and Map.has_key?(stored, sym_iter) ->
            iter_fn = Map.get(stored, sym_iter)
            iter = Invocation.invoke_callback_or_throw(iter_fn, [], obj)
            {iter, Get.get(iter, "next")}

          is_map(stored) and Map.has_key?(stored, "next") ->
            {obj, Get.get(obj, "next")}

          true ->
            {obj, :undefined}
        end
      end

      defp for_await_start_pair(obj, _sym_async_iter, _sym_iter), do: {obj, :undefined}
    end
  end
end
