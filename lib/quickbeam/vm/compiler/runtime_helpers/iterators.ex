defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Iterators do
  @moduledoc "for-of/for-in iteration, iterator close, spread, and rest."

  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Interpreter.{Context, Values}
  alias QuickBEAM.VM.ObjectModel.{Copy, Get}
  alias QuickBEAM.VM.Runtime

  def for_of_start(ctx, obj) do
    case obj do
      list when is_list(list) ->
        {{:list_iter, list}, :undefined}

      {:obj, ref} = obj_ref ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, :array.to_list(arr)}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter(ctx, custom_fn, obj_ref)
            end

          list when is_list(list) ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, list}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter(ctx, custom_fn, obj_ref)
            end

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                iter_fn = Map.get(map, sym_iter)
                iter_obj = Invocation.call_callback(ctx, iter_fn, [])
                {iter_obj, Get.get(iter_obj, "next")}

              Map.has_key?(map, "next") ->
                {obj_ref, Get.get(obj_ref, "next")}

              true ->
                {{:list_iter, []}, :undefined}
            end

          _ ->
            {{:list_iter, []}, :undefined}
        end

      s when is_binary(s) ->
        {{:list_iter, String.codepoints(s)}, :undefined}

      nil ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of null (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      :undefined ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of undefined (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      other ->
        throw(
          {:js_throw,
           Heap.make_error("#{Values.stringify(other)} is not iterable", "TypeError")}
        )
    end
  end

  def for_of_start(obj) do
    case obj do
      list when is_list(list) ->
        {{:list_iter, list}, :undefined}

      {:obj, ref} = obj_ref ->
        case Heap.get_obj(ref) do
          {:qb_arr, arr} ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, :array.to_list(arr)}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter_ctxless(custom_fn, obj_ref)
            end

          list when is_list(list) ->
            case check_array_proto_iterator(obj_ref, ref) do
              :default ->
                {{:list_iter, list}, :undefined}

              :deleted ->
                throw(
                  {:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")}
                )

              custom_fn ->
                invoke_custom_iter_ctxless(custom_fn, obj_ref)
            end

          map when is_map(map) ->
            sym_iter = {:symbol, "Symbol.iterator"}

            cond do
              Map.has_key?(map, sym_iter) ->
                iter_fn = Map.get(map, sym_iter)
                iter_obj = Runtime.call_callback(iter_fn, [])
                {iter_obj, Get.get(iter_obj, "next")}

              Map.has_key?(map, "next") ->
                {obj_ref, Get.get(obj_ref, "next")}

              true ->
                {{:list_iter, []}, :undefined}
            end

          _ ->
            {{:list_iter, []}, :undefined}
        end

      s when is_binary(s) ->
        {{:list_iter, String.codepoints(s)}, :undefined}

      nil ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of null (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      :undefined ->
        throw(
          {:js_throw,
           Heap.make_error(
             "Cannot read properties of undefined (reading 'Symbol(Symbol.iterator)')",
             "TypeError"
           )}
        )

      other ->
        throw(
          {:js_throw,
           Heap.make_error("#{Values.stringify(other)} is not iterable", "TypeError")}
        )
    end
  end

  def for_of_next(_ctx, _next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_ctx, _next_fn, {:list_iter, [head | tail]}),
    do: {false, head, {:list_iter, tail}}

  def for_of_next(_ctx, _next_fn, {:list_iter, []}), do: {true, :undefined, :undefined}

  def for_of_next(ctx, next_fn, iter_obj) do
    result = Invocation.call_callback(ctx, next_fn, [])
    done = Get.get(result, "done")
    value = Get.get(result, "value")

    if done == true do
      {true, :undefined, :undefined}
    else
      {false, value, iter_obj}
    end
  end

  def for_of_next(_next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_next_fn, {:list_iter, [head | tail]}),
    do: {false, head, {:list_iter, tail}}

  def for_of_next(_next_fn, {:list_iter, []}), do: {true, :undefined, :undefined}

  def for_of_next(next_fn, iter_obj) do
    result = Runtime.call_callback(next_fn, [])
    done = Get.get(result, "done")
    value = Get.get(result, "value")

    if done == true do
      {true, :undefined, :undefined}
    else
      {false, value, iter_obj}
    end
  end

  def for_in_start(_ctx \\ nil, obj), do: {:for_in_iterator, enumerable_keys(obj)}

  def for_in_next(_ctx \\ nil, iter)

  def for_in_next(_ctx, {:for_in_iterator, [key | rest_keys]}) do
    {false, key, {:for_in_iterator, rest_keys}}
  end

  def for_in_next(_ctx, {:for_in_iterator, []} = iter) do
    {true, :undefined, iter}
  end

  def for_in_next(_ctx, iter), do: {true, :undefined, iter}

  def iterator_close(_ctx, :undefined), do: :ok
  def iterator_close(_ctx, {:list_iter, _}), do: :ok

  def iterator_close(ctx, iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Invocation.call_callback(ctx, return_fn, [])
    end

    :ok
  end

  def iterator_close(:undefined), do: :ok
  def iterator_close({:list_iter, _}), do: :ok

  def iterator_close(iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      Runtime.call_callback(return_fn, [])
    end

    :ok
  end

  def collect_iterator(%Context{} = ctx, iter, next_fn) do
    do_collect(ctx, iter, next_fn, [])
  end

  def collect_iterator(iter, next_fn) do
    do_collect_ctxless(iter, next_fn, [])
  end

  def append_spread(_ctx \\ nil, arr, idx, obj), do: Copy.append_spread(arr, idx, obj)

  def rest(ctx, start_idx) do
    arg_buf = QuickBEAM.VM.Compiler.RuntimeHelpers.Coercion.context_arg_buf(ctx)

    rest_args =
      if start_idx < tuple_size(arg_buf) do
        Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
      else
        []
      end

    Heap.wrap(rest_args)
  end

  defp do_collect(ctx, iter, next_fn, acc) do
    case for_of_next(ctx, next_fn, iter) do
      {true, _, _} -> Heap.wrap(Enum.reverse(acc))
      {false, val, new_iter} -> do_collect(ctx, new_iter, next_fn, [val | acc])
    end
  end

  defp do_collect_ctxless(iter, next_fn, acc) do
    case for_of_next(next_fn, iter) do
      {true, _, _} -> Heap.wrap(Enum.reverse(acc))
      {false, val, new_iter} -> do_collect_ctxless(new_iter, next_fn, [val | acc])
    end
  end

  defp enumerable_keys(obj), do: Copy.enumerable_keys(obj)

  defp check_array_proto_iterator({:obj, _ref}, _raw_ref) do
    sym_iter = {:symbol, "Symbol.iterator"}

    case Heap.get_array_proto() do
      {:obj, proto_ref} ->
        proto_data = Heap.get_obj(proto_ref, %{})

        case is_map(proto_data) && Map.get(proto_data, sym_iter) do
          nil -> :deleted
          false -> :deleted
          :deleted -> :deleted
          {:builtin, "[Symbol.iterator]", _} -> :default
          other -> other
        end

      _ ->
        :default
    end
  end

  defp invoke_custom_iter(_ctx, iter_fn, obj) do
    iter_obj = Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

    unless is_object(iter_obj) do
      throw(
        {:js_throw,
         Heap.make_error("Result of the Symbol.iterator method is not an object", "TypeError")}
      )
    end

    {iter_obj, Get.get(iter_obj, "next")}
  end

  defp invoke_custom_iter_ctxless(iter_fn, obj) do
    iter_obj = Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

    unless is_object(iter_obj) do
      throw(
        {:js_throw,
         Heap.make_error("Result of the Symbol.iterator method is not an object", "TypeError")}
      )
    end

    {iter_obj, Get.get(iter_obj, "next")}
  end
end
