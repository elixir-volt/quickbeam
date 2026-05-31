defmodule QuickBEAM.VM.Runtime.Object.Entries do
  @moduledoc "Object.fromEntries and Object.groupBy helpers."

  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0, proto: 0]
  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.{Heap, Invocation, Runtime, Value}
  alias QuickBEAM.VM.ObjectModel.{Define, Get, PropertyKey, WrappedPrimitive}
  alias QuickBEAM.VM.Semantics.Iterators

  def from_entries([iterable | _]) do
    source_entries = entries_from_iterable(iterable)
    result = new_result_object()
    {:obj, result_ref} = result

    order = add_from_entries(source_entries, result_ref, [])
    Heap.put_obj_key(result_ref, key_order(), order)

    result
  end

  def from_entries(_) do
    throw({:js_throw, Heap.make_error("Object.fromEntries requires an iterable", "TypeError")})
  end

  def group_by([items, callback | _]) do
    unless QuickBEAM.VM.Builtin.callable?(callback) do
      throw({:js_throw, Heap.make_error("callback is not callable", "TypeError")})
    end

    result = Heap.wrap(%{proto() => :null_proto})
    {iter, next_fn} = Iterators.for_of_start(items)
    do_group_by(result, iter, next_fn, callback, 0)
  end

  def group_by(_),
    do: throw({:js_throw, Heap.make_error("callback is not callable", "TypeError")})

  defp new_result_object do
    case QuickBEAM.VM.Runtime.ConstructorRegistry.class_proto("Object") do
      {:obj, _} = proto ->
        ref = make_ref()
        Heap.put_obj(ref, %{proto() => proto, key_order() => []})
        {:obj, ref}

      _ ->
        Runtime.new_object()
    end
  end

  defp do_group_by(result, :undefined, _next_fn, _callback, _index), do: result

  defp do_group_by(result, iter, next_fn, callback, index) do
    {done?, value, next_iter} = Iterators.for_of_next(next_fn, iter)

    if done? do
      result
    else
      key = group_property_key(callback, value, index, iter)
      append_group_value(result, key, value)
      do_group_by(result, next_iter, next_fn, callback, index + 1)
    end
  end

  defp group_property_key(callback, value, index, iter) do
    callback
    |> Invocation.invoke_with_receiver([value, index], :undefined)
    |> PropertyKey.to_property_key()
  catch
    {:js_throw, error} ->
      Iterators.iterator_close(iter)
      throw({:js_throw, error})
  end

  defp append_group_value({:obj, _} = result, key, value) do
    case Get.get(result, key) do
      {:obj, ref} = array ->
        Heap.array_push(ref, [value])
        array

      _ ->
        Define.create_data_property_or_throw(result, key, Heap.wrap([value]))
    end
  end

  defp entries_from_iterable({:obj, ref} = iterable) do
    iterator_method = Get.get(iterable, {:symbol, "Symbol.iterator"})

    if not Value.nullish?(iterator_method) do
      iterator = invoke_with_this(iterator_method, [], iterable)
      {:iterator, iterator}
    else
      case Heap.obj_to_list(ref) do
        list when is_list(list) -> list
        _ -> []
      end
    end
  end

  defp entries_from_iterable(_iterable) do
    throw({:js_throw, Heap.make_error("Object.fromEntries requires an iterable", "TypeError")})
  end

  defp add_from_entries({:iterator, iterator}, result_ref, order) do
    next_fn = Get.get(iterator, "next")

    unless QuickBEAM.VM.Builtin.callable?(next_fn) do
      throw({:js_throw, Heap.make_error("Iterator next is not callable", "TypeError")})
    end

    result = invoke_with_this(next_fn, [], iterator)

    unless match?({:obj, _}, result) or is_map(result) do
      throw({:js_throw, Heap.make_error("Iterator result is not an object", "TypeError")})
    end

    if Get.get(result, "done") == true do
      order
    else
      entry = Get.get(result, "value")

      try do
        [key, value | _] = entry_pair(entry)
        prop_key = from_entries_property_key(key)
        Heap.put_obj_key(result_ref, prop_key, value)
        add_from_entries({:iterator, iterator}, result_ref, updated_order(order, prop_key))
      catch
        {:js_throw, _} = thrown ->
          close_iterator(iterator)
          throw(thrown)
      end
    end
  end

  defp add_from_entries(entries, result_ref, order) when is_list(entries) do
    Enum.reduce(entries, order, fn entry, acc ->
      [key, value | _] = entry_pair(entry)
      prop_key = from_entries_property_key(key)
      Heap.put_obj_key(result_ref, prop_key, value)
      updated_order(acc, prop_key)
    end)
  end

  defp updated_order(order, prop_key) do
    if is_binary(prop_key) and prop_key not in order, do: [prop_key | order], else: order
  end

  defp from_entries_property_key({:obj, _} = key) do
    case Get.get(key, {:symbol, "Symbol.toPrimitive"}) do
      primitive_fn when not is_nullish(primitive_fn) ->
        primitive =
          Invocation.invoke_with_receiver(primitive_fn, ["string"], Runtime.gas_budget(), key)

        PropertyKey.normalize(primitive)

      _ ->
        PropertyKey.normalize(key)
    end
  end

  defp from_entries_property_key(key), do: PropertyKey.normalize(key)

  defp close_iterator(iterator) do
    case Get.get(iterator, "return") do
      return_fn when not is_nullish(return_fn) ->
        invoke_with_this(return_fn, [], iterator)

      _ ->
        :undefined
    end
  end

  defp entry_pair([_, _ | _] = entry), do: entry

  defp entry_pair({:obj, ref} = entry) do
    case Heap.to_list(entry) do
      [_, _ | _] = pair ->
        pair

      _ ->
        case Heap.get_obj(ref, %{}) |> WrappedPrimitive.value(:string) do
          {:ok, <<key::utf8, value::utf8, _::binary>>} -> [<<key::utf8>>, <<value::utf8>>]
          _ -> entry_pair_from_properties(entry)
        end
    end
  end

  defp entry_pair(_entry) do
    throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
  end

  defp entry_pair_from_properties(entry) do
    key = Get.get(entry, "0")

    if key == :undefined do
      throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
    end

    value = Get.get(entry, "1")

    if value == :undefined do
      _ = from_entries_property_key(key)
      throw({:js_throw, Heap.make_error("Iterator value is not an entry object", "TypeError")})
    end

    [key, value]
  end

  defp invoke_with_this(fun, args, this) do
    case fun do
      {:builtin, _, callback} when is_function(callback) ->
        callback.(args, this)

      %QuickBEAM.VM.Function{} = function ->
        Invocation.invoke_with_receiver(function, args, Runtime.gas_budget(), this)

      {:closure, _, %QuickBEAM.VM.Function{}} = closure ->
        Invocation.invoke_with_receiver(closure, args, Runtime.gas_budget(), this)

      _ ->
        Runtime.call_callback(fun, args)
    end
  end
end
