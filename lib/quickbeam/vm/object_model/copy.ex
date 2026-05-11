defmodule QuickBEAM.VM.ObjectModel.Copy do
  @moduledoc "Object spread and property copying: `append_spread`, `copy_data_properties`, and array/iterator flattening."

  import QuickBEAM.VM.Heap.Keys,
    only: [key_order: 0, map_data: 0, proto: 0, proxy_handler: 0, proxy_target: 0, set_data: 0]

  import QuickBEAM.VM.Value, only: [is_symbol: 1]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.ObjectModel.Get

  @doc "Appends values from a spread source into an array-like target and returns the next index."
  def append_spread(arr, idx, obj) do
    src_list = spread_source_to_list(obj)
    arr_list = spread_target_to_list(arr)
    new_idx = if(is_integer(idx), do: idx, else: Runtime.to_int(idx)) + length(src_list)
    merged = arr_list ++ src_list

    merged_obj =
      case arr do
        {:obj, ref} ->
          Heap.put_obj(ref, merged)
          {:obj, ref}

        _ ->
          merged
      end

    {new_idx, merged_obj}
  end

  @doc "Copies enumerable string properties from a source object to a target object."
  def copy_data_properties(target, source, exclude \\ nil) do
    src_props = enumerable_string_props(source)

    src_props =
      case exclude do
        {:obj, eref} ->
          exclude_keys =
            case Heap.get_obj(eref) do
              {:qb_arr, arr} -> :array.to_list(arr) |> Enum.map(&property_key/1)
              list when is_list(list) -> Enum.map(list, &property_key/1)
              map when is_map(map) -> enumerable_copy_keys(map) |> Enum.map(&property_key/1)
              _ -> []
            end

          Map.drop(src_props, exclude_keys)

        _ ->
          src_props
      end

    case target do
      {:obj, ref} ->
        existing = Heap.get_obj(ref, %{})
        existing = if is_map(existing), do: existing, else: %{}
        merged = Map.merge(existing, src_props)

        merged =
          case Map.get(merged, key_order()) do
            order when is_list(order) ->
              new_keys = Map.keys(src_props) -- order
              Map.put(merged, key_order(), Enum.reverse(new_keys) ++ order)

            _ ->
              merged
          end

        Heap.put_obj(ref, merged)

      _ ->
        :ok
    end

    :ok
  end

  @doc "Returns enumerable own string and symbol properties as a map of property names to values."
  def enumerable_string_props({:obj, ref} = source_obj) do
    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, _offsets, vals, _proto} ->
        map = shape_enumerable_map(shape_id, vals)
        resolve_accessors(map, source_obj)

      {:qb_arr, arr} ->
        arr
        |> :array.sparse_to_orddict()
        |> Enum.reduce(%{}, fn {i, _value}, acc ->
          Map.put(acc, Integer.to_string(i), Get.get(source_obj, Integer.to_string(i)))
        end)

      list when is_list(list) ->
        Enum.reduce(0..max(length(list) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Get.get(source_obj, Integer.to_string(i)))
        end)

      %{proxy_target() => _target, proxy_handler() => _handler} = proxy_map ->
        proxy_enumerable_string_props(source_obj, proxy_map)

      map when is_map(map) ->
        map
        |> Map.keys()
        |> Enum.filter(&enumerable_key_candidate?/1)
        |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)
        |> Enum.reduce(%{}, fn key, acc -> Map.put(acc, key, Get.get(source_obj, key)) end)

      _ ->
        %{}
    end
  end

  def enumerable_string_props(map) when is_map(map), do: map
  def enumerable_string_props(_), do: %{}

  defp proxy_enumerable_string_props(source_obj, %{
         proxy_target() => target,
         proxy_handler() => handler
       }) do
    keys =
      case Get.get(handler, "ownKeys") do
        trap when trap != nil and trap != :undefined ->
          trap
          |> Runtime.call_callback([target])
          |> Heap.to_list()

        _ ->
          []
      end

    descriptor_trap = Get.get(handler, "getOwnPropertyDescriptor")

    Enum.reduce(keys, %{}, fn key, acc ->
      descriptor =
        if descriptor_trap != nil and descriptor_trap != :undefined do
          Runtime.call_callback(descriptor_trap, [target, key])
        else
          :undefined
        end

      if property_key?(key) and descriptor != :undefined and
           Get.get(descriptor, "enumerable") == true do
        Map.put(acc, key, Get.get(source_obj, key))
      else
        acc
      end
    end)
  end

  defp shape_enumerable_map(shape_id, vals) do
    shape_id
    |> Heap.Shapes.to_map(vals, nil)
    |> Map.delete(key_order())
  end

  defp resolve_accessors(map, obj) do
    Map.new(map, fn
      {k, {:accessor, getter, _}} when getter != nil -> {k, Get.call_getter(getter, obj)}
      pair -> pair
    end)
  end

  @doc "Returns enumerable property keys in JavaScript enumeration order."
  def enumerable_keys({:obj, ref} = obj) do
    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, _offsets, _vals, proto} ->
        own_keys = Heap.Shapes.keys(shape_id) |> Enum.filter(&enumerable_key_candidate?/1)
        proto_keys = enumerable_proto_keys(proto)
        Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))

      raw ->
        enumerable_keys_from_raw(obj, ref, raw)
    end
  end

  def enumerable_keys(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(fn key -> String.starts_with?(key, "__") and String.ends_with?(key, "__") end)
    |> Runtime.sort_numeric_keys()
  end

  def enumerable_keys(list) when is_list(list), do: numeric_index_keys(length(list))

  def enumerable_keys(string) when is_binary(string),
    do: numeric_index_keys(Get.string_length(string))

  def enumerable_keys({:bound, _, _, _, _} = fun), do: enumerable_callable_keys(fun)

  def enumerable_keys(_), do: []

  defp enumerable_keys_from_raw(obj, ref, raw) do
    case raw || %{} do
      %{proxy_target() => _target, proxy_handler() => handler} ->
        own_keys_fn = Get.get(handler, "ownKeys")

        if own_keys_fn != :undefined and own_keys_fn != nil do
          result = Runtime.call_callback(own_keys_fn, [obj])
          Heap.to_list(result) |> Enum.map(&to_string/1)
        else
          []
        end

      {:qb_arr, arr} ->
        (array_prop_keys(ref) ++
           (arr
            |> :array.sparse_to_orddict()
            |> Enum.map(fn {index, _value} -> Integer.to_string(index) end)
            |> Enum.reject(fn key ->
              match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
            end)))
        |> Runtime.sort_numeric_keys()

      list when is_list(list) ->
        numeric_index_keys(length(list))

      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        all_own = Map.keys(map) |> Enum.filter(&is_binary/1)
        proto_keys = enumerable_proto_keys(Map.get(map, proto()))
        Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in all_own)))

      _ ->
        []
    end
  end

  @doc "Converts a spread source value into the list of values to append."
  def spread_source_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_source_to_list(list) when is_list(list), do: list
  def spread_source_to_list(string) when is_binary(string), do: String.codepoints(string)

  def spread_source_to_list({:obj, ref}) do
    case Heap.get_obj(ref) do
      {:qb_arr, arr} ->
        :array.to_list(arr)

      list when is_list(list) ->
        list

      map when is_map(map) ->
        cond do
          Map.has_key?(map, {:symbol, "Symbol.iterator"}) ->
            iter_fn = Map.get(map, {:symbol, "Symbol.iterator"})
            iter_obj = Runtime.call_callback(iter_fn, [])
            collect_iterator_values(iter_obj, [])

          Map.has_key?(map, set_data()) ->
            Map.get(map, set_data(), [])

          Map.has_key?(map, map_data()) ->
            Map.get(map, map_data(), [])

          true ->
            []
        end

      _ ->
        []
    end
  end

  def spread_source_to_list(_), do: []

  @doc "Converts a spread target value into its current list representation."
  def spread_target_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_target_to_list(list) when is_list(list), do: list
  def spread_target_to_list({:obj, _} = obj), do: Heap.to_list(obj)
  def spread_target_to_list(_), do: []

  defp collect_iterator_values(iter_obj, acc) do
    next_fn = Get.get(iter_obj, "next")
    result = Runtime.call_callback(next_fn, [])

    if Get.get(result, "done") do
      Enum.reverse(acc)
    else
      collect_iterator_values(iter_obj, [Get.get(result, "value") | acc])
    end
  end

  defp array_prop_keys(ref) do
    ref
    |> Heap.get_array_props()
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_binary(key) and not String.starts_with?(key, "__") and
        not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
    end)
  end

  defp enumerable_object_keys(map, ref) do
    raw_keys =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> []
      end

    raw_keys = raw_keys ++ (Map.keys(map) -- raw_keys)

    raw_keys
    |> Enum.filter(&enumerable_key_candidate?/1)
    |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)
  end

  defp enumerable_callable_keys(fun) do
    own_keys =
      fun
      |> Heap.get_ctor_statics()
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(fn key -> not match?(%{enumerable: false}, Heap.get_prop_desc(fun, key)) end)

    proto_keys =
      case Heap.get_func_proto() do
        {:obj, _} = proto -> enumerable_keys(proto)
        _ -> []
      end

    Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))
  end

  defp enumerable_proto_keys({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        parent_keys = enumerable_proto_keys(Map.get(map, proto()))
        own_keys ++ Enum.reject(parent_keys, &(&1 in own_keys))

      _ ->
        []
    end
  end

  defp enumerable_proto_keys(_), do: []

  defp enumerable_key_candidate?(key) when is_binary(key),
    do: not (String.starts_with?(key, "__") and String.ends_with?(key, "__"))

  defp enumerable_key_candidate?(key) when is_symbol(key), do: true
  defp enumerable_key_candidate?(_), do: false

  defp property_key?(key), do: is_binary(key) or is_symbol(key)

  defp property_key(key) when is_symbol(key), do: key
  defp property_key(key), do: to_string(key)

  defp enumerable_copy_keys(map) do
    string_keys =
      map
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(fn key ->
        String.starts_with?(key, "__") and String.ends_with?(key, "__")
      end)

    symbol_keys = Map.keys(map) |> Enum.filter(&is_symbol/1)
    string_keys ++ symbol_keys
  end

  defp numeric_index_keys(size) when size <= 0, do: []
  defp numeric_index_keys(size), do: Enum.map(0..(size - 1), &Integer.to_string/1)
end
