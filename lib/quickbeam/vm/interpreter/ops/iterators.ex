defmodule QuickBEAM.VM.Interpreter.Ops.Iterators do
  @moduledoc "For-in, for-of, iterator_*, spread, and array construction opcodes."

  defmacro __using__(_opts) do
    quote location: :keep do
      import Bitwise, only: [band: 2]
      alias QuickBEAM.VM.{Heap, Invocation, Runtime}
      alias QuickBEAM.VM.Interpreter.Context
      alias QuickBEAM.VM.ObjectModel.{Copy, Get, Put}

      # ── for-in ──

      defp run({@op_for_in_start, []}, _pc, frame, [obj | _rest], gas, ctx)
           when obj == :uninitialized do
        throw_or_catch(frame, Heap.make_error("this is not initialized", "ReferenceError"), gas, ctx)
      end

      defp run({@op_for_in_start, []}, pc, frame, [obj | rest], gas, ctx) do
        keys = Copy.enumerable_keys(obj)
        run(pc + 1, frame, [{:for_in_iterator, keys, obj} | rest], gas, ctx)
      end

      defp run(
             {@op_for_in_next, []} = instr,
             pc,
             frame,
             [{:for_in_iterator, [key | rest_keys], obj} | rest],
             gas,
             ctx
           ) do
        if Put.has_property(obj, key) do
          run(pc + 1, frame, [false, key, {:for_in_iterator, rest_keys, obj} | rest], gas, ctx)
        else
          run(instr, pc, frame, [{:for_in_iterator, rest_keys, obj} | rest], gas, ctx)
        end
      end

      defp run({@op_for_in_next, []}, pc, frame, [iter | rest], gas, ctx) do
        run(pc + 1, frame, [true, :undefined, iter | rest], gas, ctx)
      end

      # ── spread / array construction ──

      defp run({@op_append, []}, pc, frame, [obj, idx, arr | rest], gas, ctx) do
        src_list =
          case obj do
            {:qb_arr, arr} ->
              :array.to_list(arr)

            list when is_list(list) ->
              list

            {:obj, ref} ->
              stored = Heap.get_obj(ref)

              cond do
                match?({:qb_arr, _}, stored) ->
                  Heap.to_list({:obj, ref})

                is_list(stored) ->
                  stored

                is_map(stored) and Map.has_key?(stored, {:symbol, "Symbol.iterator"}) ->
                  raw_iter = Map.get(stored, {:symbol, "Symbol.iterator"})

                  iter_fn =
                    case raw_iter do
                      {:accessor, getter, _} when getter != nil -> Get.call_getter(getter, obj)
                      _ -> raw_iter
                    end

                  iter_obj = Invocation.invoke_callback_or_throw(iter_fn, [], obj)

                  unless is_object(iter_obj) do
                    throw(
                      {:js_throw,
                       Heap.make_error(
                         "Result of the Symbol.iterator method is not an object",
                         "TypeError"
                       )}
                    )
                  end

                  collect_iterator(iter_obj, [])

                is_map(stored) and Map.has_key?(stored, set_data()) ->
                  Map.get(stored, set_data(), [])

                is_map(stored) and Map.has_key?(stored, map_data()) ->
                  Map.get(stored, map_data(), [])

                true ->
                  []
              end

            _ ->
              []
          end

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
        {_idx, obj2} = Put.define_array_el(obj, idx, val)
        run(pc + 1, frame, [idx, obj2 | rest], gas, ctx)
      end

      # ── Iterators ──

      defp run({@op_for_of_start, []}, pc, frame, [obj | rest], gas, ctx) do
        result =
          try do
            {:ok, for_of_start_iter(obj)}
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

        if iter_obj == :undefined do
          run(pc + 1, frame, [true, :undefined | stack], gas, ctx)
        else
          result = Invocation.invoke_callback_or_throw(next_fn, [])

          ctx =
            case Heap.get_persistent_globals() do
              nil -> ctx
              p when map_size(p) == 0 -> ctx
              p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
            end

          done = Get.get(result, "done")
          value = Get.get(result, "value")

          if done == true do
            cleared = List.replace_at(stack, offset - 1, :undefined)
            run(pc + 1, frame, [true, :undefined | cleared], gas, ctx)
          else
            run(pc + 1, frame, [false, value | stack], gas, ctx)
          end
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
        result = Invocation.invoke_callback_or_throw(next_fn, [val])
        persistent = Heap.get_persistent_globals() || %{}
        ctx = Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent)})
        run(pc + 1, frame, [result, catch_offset, next_fn, iter_obj | rest], gas, ctx)
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
        ctx =
          if iter_obj != :undefined do
            return_fn = Get.get(iter_obj, "return")

            if return_fn != :undefined and return_fn != nil do
              Invocation.invoke_callback_or_throw(return_fn, [], iter_obj)
              persistent = Heap.get_persistent_globals() || %{}
              Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, persistent)})
            else
              ctx
            end
          else
            ctx
          end

        run(pc + 1, frame, rest, gas, ctx)
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
        {iter_obj, next_fn} =
          case obj do
            {:obj, ref} ->
              stored = Heap.get_obj(ref, [])

              cond do
                match?({:qb_arr, _}, stored) ->
                  make_list_iterator(Heap.to_list({:obj, ref}))

                is_list(stored) ->
                  make_list_iterator(stored)

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
