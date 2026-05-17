defmodule QuickBEAM.VM.Interpreter.Ops.Iterators do
  @moduledoc "For-in, for-of, iterator_*, spread, and array construction opcodes."

  @doc "Installs the For-in, for-of, iterator_*, spread, and array construction opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      import Bitwise, only: [band: 2]
      alias QuickBEAM.VM.{Heap, Invocation, Runtime}
      alias QuickBEAM.VM.Interpreter.Context
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
          ctx = QuickBEAM.VM.GlobalEnv.refresh(Heap.get_ctx() || ctx)
          val = resolve_delayed_define_value(val, ctx)
          {_idx, obj2} = Put.define_array_el(obj, idx, val)
          run(pc + 1, frame, [idx, obj2 | rest], gas, ctx)
        catch
          {:js_throw, error} ->
            ctx = Heap.get_ctx() || ctx
            throw_or_catch(frame, error, gas, ctx)
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

        {done?, value, next_iter} = Iterators.for_of_next(ctx, next_fn, iter_obj)

        ctx =
          case Heap.get_persistent_globals() do
            nil -> ctx
            p when map_size(p) == 0 -> ctx
            p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
          end

        updated_stack = List.replace_at(stack, offset - 1, next_iter)

        if done? do
          run(pc + 1, frame, [true, :undefined | updated_stack], gas, ctx)
        else
          run(pc + 1, frame, [false, value | updated_stack], gas, ctx)
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
        {result, next_iter} = Iterators.iterator_next_result(ctx, next_fn, iter_obj, val)
        persistent = Heap.get_persistent_globals() || %{}
        ctx = Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent)})
        run(pc + 1, frame, [result, catch_offset, next_fn, next_iter | rest], gas, ctx)
      end

      defp run({@op_iterator_get_value_done, []}, pc, frame, [result | rest], gas, ctx) do
        done = Get.get(result, "done")
        value = Get.get(result, "value")

        if done == true do
          run(pc + 1, frame, [true, :undefined | rest], gas, ctx)
        else
          run(pc + 1, frame, [false, value | rest], gas, ctx)
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
            {:ok, Heap.get_ctx() || ctx}
          catch
            {:js_throw, error} -> {:throw, error}
          end

        case result do
          {:ok, ctx} ->
            persistent = Heap.get_persistent_globals() || %{}
            ctx = Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent)})
            run(pc + 1, frame, rest, gas, ctx)

          {:throw, error} ->
            throw_or_catch(frame, error, gas, ctx)
        end
      end

      defp run({@op_iterator_check_object, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      defp run({@op_iterator_call, [flags]}, pc, frame, stack, gas, ctx) do
        [_val, _catch_offset, _next_fn, iter_obj | _] = stack
        method_name = if band(flags, 1) == 1, do: "throw", else: "return"
        method = Get.get(iter_obj, method_name)

        if method == :undefined or method == nil do
          run(pc + 1, frame, [true | stack], gas, ctx)
        else
          result =
            if band(flags, 2) == 2 do
              Runtime.call_callback(method, [])
            else
              [val | _] = stack
              Runtime.call_callback(method, [val])
            end

          [_ | rest] = stack
          run(pc + 1, frame, [false, result | rest], gas, ctx)
        end
      end

      defp run({@op_iterator_call, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, stack, gas, ctx)

      # ── for-await-of ──

      defp run({@op_for_await_of_start, []}, pc, frame, [obj | rest], gas, ctx) do
        sym_async_iter = {:symbol, "Symbol.asyncIterator"}
        sym_iter = {:symbol, "Symbol.iterator"}

        {iter_obj, next_fn} =
          case obj do
            {:obj, ref} ->
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

            _ ->
              {obj, :undefined}
          end

        run(pc + 1, frame, [0, next_fn, iter_obj | rest], gas, ctx)
      end
    end
  end
end
