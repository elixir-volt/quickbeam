defmodule QuickBEAM.VM.Semantics.Iterators do
  @moduledoc "Shared ECMAScript iterator semantics for interpreter and compiled runtime adapters."

  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Builtin, Heap, Invocation, Runtime}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Copy, Get, HasProperty}
  alias QuickBEAM.VM.Runtime.Collections

  @doc "Creates iterator state for a JavaScript `for...of` loop."
  def for_of_start(%Context{} = ctx, obj), do: start_for_of(ctx, obj)
  def for_of_start(obj), do: start_for_of(nil, obj)

  @doc "Advances JavaScript `for...of` iterator state."
  def for_of_next(_ctx, next_fn, iter), do: for_of_next(next_fn, iter)

  def for_of_next(_next_fn, :undefined), do: {true, :undefined, :undefined}

  def for_of_next(_next_fn, {:list_iter, [head | tail]}),
    do: {false, head, {:list_iter, tail}}

  def for_of_next(_next_fn, {:list_iter, []}), do: {true, :undefined, :undefined}

  def for_of_next(next_fn, iter_obj) do
    result = Invocation.invoke_with_receiver(next_fn, [], iter_obj)
    done = Get.get(result, "done")
    value = Get.get(result, "value")

    if done == true do
      {true, :undefined, :undefined}
    else
      {false, value, iter_obj}
    end
  end

  def iterator_next_result(ctx \\ nil, next_fn, iter_obj, val)

  def iterator_next_result(_ctx, _next_fn, :undefined, _val),
    do: {Heap.wrap(%{"done" => true, "value" => :undefined}), :undefined}

  def iterator_next_result(_ctx, _next_fn, {:list_iter, [head | tail]}, _val),
    do: {Heap.wrap(%{"done" => false, "value" => head}), {:list_iter, tail}}

  def iterator_next_result(_ctx, _next_fn, {:list_iter, []}, _val),
    do: {Heap.wrap(%{"done" => true, "value" => :undefined}), :undefined}

  def iterator_next_result(_ctx, next_fn, iter_obj, val) do
    result = Invocation.invoke_callback_or_throw(next_fn, [val])
    next_iter = if Get.get(result, "done") == true, do: :undefined, else: iter_obj
    {result, next_iter}
  end

  @doc "Collects values from an iterable according to ECMAScript iterator protocol."
  def iterable_to_list(value), do: collect_iterable_values(value)

  @doc "Creates key iteration state for a JavaScript `for...in` loop."
  def for_in_start(_ctx \\ nil, obj), do: {:for_in_iterator, Copy.enumerable_keys(obj), obj}

  def for_in_next(ctx \\ nil, iter)

  def for_in_next(ctx, {:for_in_iterator, [key | rest_keys], obj}) do
    if HasProperty.has_property?(obj, key) do
      {false, key, {:for_in_iterator, rest_keys, obj}}
    else
      for_in_next(ctx, {:for_in_iterator, rest_keys, obj})
    end
  end

  def for_in_next(_ctx, {:for_in_iterator, []} = iter), do: {true, :undefined, iter}
  def for_in_next(_ctx, {:for_in_iterator, [], _obj} = iter), do: {true, :undefined, iter}
  def for_in_next(_ctx, iter), do: {true, :undefined, iter}

  @doc "Closes an iterator by calling its `return` method when present."
  def iterator_close(%Context{} = ctx, iter_obj), do: close_iterator(ctx, iter_obj)
  def iterator_close(iter_obj), do: close_iterator(nil, iter_obj)

  @doc "Collects remaining values from an iterator into a list object."
  def collect_iterator(%Context{} = ctx, iter, next_fn), do: do_collect(ctx, iter, next_fn, [])
  def collect_iterator(iter, next_fn), do: do_collect(nil, iter, next_fn, [])

  defp start_for_of(_ctx, list) when is_list(list), do: {{:list_iter, list}, :undefined}

  defp start_for_of(ctx, {:obj, ref} = obj_ref) do
    case Heap.get_obj(ref) do
      {:qb_arr, arr} ->
        array_like_for_of(ctx, obj_ref, :array.to_list(arr))

      list when is_list(list) ->
        array_like_for_of(ctx, obj_ref, list)

      map when is_map(map) ->
        object_for_of(ctx, obj_ref, map)

      _ ->
        {{:list_iter, []}, :undefined}
    end
  end

  defp start_for_of(_ctx, value) when is_binary(value),
    do: {{:list_iter, string_codepoints(value)}, :undefined}

  defp start_for_of(_ctx, nil) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot read properties of null (reading 'Symbol(Symbol.iterator)')",
         "TypeError"
       )}
    )
  end

  defp start_for_of(_ctx, :undefined) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot read properties of undefined (reading 'Symbol(Symbol.iterator)')",
         "TypeError"
       )}
    )
  end

  defp start_for_of(_ctx, other) do
    throw({:js_throw, Heap.make_error("#{Values.stringify(other)} is not iterable", "TypeError")})
  end

  defp collect_iterable_values(list) when is_list(list), do: list
  defp collect_iterable_values({:qb_arr, arr}), do: :array.to_list(arr)
  defp collect_iterable_values(value) when is_binary(value), do: string_codepoints(value)

  defp collect_iterable_values({:obj, ref} = obj) do
    case Heap.get_obj(ref) do
      {:qb_arr, arr} ->
        collect_array_like_values(obj, :array.to_list(arr))

      list when is_list(list) ->
        collect_array_like_values(obj, list)

      map when is_map(map) ->
        collect_object_iterable_values(obj, map)

      _ ->
        not_iterable!()
    end
  end

  defp collect_iterable_values(_), do: not_iterable!()

  defp collect_array_like_values(obj, default_values) do
    case Collections.array_proto_iterator_status() do
      :default -> default_values
      :deleted -> not_iterable!()
      iter_fn -> collect_custom_iterator(obj, iter_fn)
    end
  end

  defp collect_object_iterable_values(obj, map) do
    iter_fn = Get.get(obj, {:symbol, "Symbol.iterator"})

    cond do
      Builtin.callable?(iter_fn) ->
        collect_custom_iterator(obj, iter_fn)

      iter_fn not in [nil, :undefined] ->
        not_iterable!()

      Map.has_key?(map, "__set_data__") ->
        Map.get(map, "__set_data__", [])

      Map.has_key?(map, "__map_data__") ->
        Map.get(map, "__map_data__", [])

      true ->
        not_iterable!()
    end
  end

  defp collect_custom_iterator(obj, iter_fn) do
    iterator = Invocation.invoke_with_receiver(iter_fn, [], Runtime.gas_budget(), obj)

    unless is_object(iterator), do: not_iterable!()

    next_fn = Get.get(iterator, "next")
    unless Builtin.callable?(next_fn), do: not_iterable!()

    do_collect_iterator_values(iterator, next_fn, [])
  end

  defp do_collect_iterator_values(iterator, next_fn, acc) do
    try do
      result = Invocation.invoke_with_receiver(next_fn, [], iterator)
      unless is_object(result), do: iterator_type_error!("iterator result is not an object")

      if Runtime.truthy?(Get.get(result, "done")) do
        Enum.reverse(acc)
      else
        do_collect_iterator_values(iterator, next_fn, [Get.get(result, "value") | acc])
      end
    catch
      {:js_throw, _} = reason ->
        close_iterator(nil, iterator)
        throw(reason)
    end
  end

  defp not_iterable!, do: iterator_type_error!("object is not iterable")

  defp iterator_type_error!(message),
    do: throw({:js_throw, Heap.make_error(message, "TypeError")})

  defp array_like_for_of(ctx, obj_ref, values) do
    case Collections.array_proto_iterator_status() do
      :default ->
        {{:list_iter, values}, :undefined}

      :deleted ->
        throw({:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")})

      custom_fn ->
        invoke_custom_iter(ctx, custom_fn, obj_ref)
    end
  end

  defp object_for_of(ctx, obj_ref, map) do
    iter_fn = Get.get(obj_ref, {:symbol, "Symbol.iterator"})

    cond do
      Builtin.callable?(iter_fn) ->
        invoke_custom_iter(ctx, iter_fn, obj_ref)

      iter_fn not in [nil, :undefined] ->
        throw({:js_throw, Heap.make_error("[Symbol.iterator] is not a function", "TypeError")})

      Map.has_key?(map, "next") ->
        {obj_ref, Get.get(obj_ref, "next")}

      true ->
        {{:list_iter, []}, :undefined}
    end
  end

  defp close_iterator(_ctx, :undefined), do: :ok
  defp close_iterator(_ctx, {:list_iter, _}), do: :ok

  defp close_iterator(%Context{} = ctx, iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      ctx
      |> Invocation.invoke_method_runtime(return_fn, iter_obj, [])
      |> validate_iterator_close_result!()
    end

    :ok
  end

  defp close_iterator(_ctx, iter_obj) do
    return_fn = Get.get(iter_obj, "return")

    if return_fn != :undefined and return_fn != nil do
      return_fn
      |> Invocation.invoke_method_runtime(iter_obj, [])
      |> validate_iterator_close_result!()
    end

    :ok
  end

  defp validate_iterator_close_result!(result) do
    unless is_object(result), do: iterator_type_error!("iterator return result is not an object")
    result
  end

  defp do_collect(ctx, iter, next_fn, acc) do
    case for_of_next(ctx, next_fn, iter) do
      {true, _, _} -> Heap.wrap(Enum.reverse(acc))
      {false, val, new_iter} -> do_collect(ctx, new_iter, next_fn, [val | acc])
    end
  end

  defp string_codepoints(<<>>), do: []

  defp string_codepoints(<<0xED, b2, b3, rest::binary>>)
       when b2 in 0xA0..0xBF and b3 in 0x80..0xBF do
    [<<0xED, b2, b3>> | string_codepoints(rest)]
  end

  defp string_codepoints(<<cp::utf8, rest::binary>>) do
    [<<cp::utf8>> | string_codepoints(rest)]
  end

  defp string_codepoints(<<byte, rest::binary>>) do
    [<<byte>> | string_codepoints(rest)]
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
end
