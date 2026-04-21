defmodule QuickBEAM.VM.ObjectModel.Copy do
  @moduledoc false

  import QuickBEAM.VM.Heap.Keys,
    only: [key_order: 0, map_data: 0, proto: 0, proxy_handler: 0, proxy_target: 0, set_data: 0]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.ObjectModel.Get

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

  def copy_data_properties(target, source) do
    src_props = enumerable_string_props(source)

    case target do
      {:obj, ref} ->
        existing = Heap.get_obj(ref, %{})
        existing = if is_map(existing), do: existing, else: %{}
        Heap.put_obj(ref, Map.merge(existing, src_props))

      _ ->
        :ok
    end

    :ok
  end

  def enumerable_string_props({:obj, ref} = source_obj) do
    case Heap.get_obj(ref, %{}) do
      {:qb_arr, _} ->
        Enum.reduce(0..max(Heap.array_size(ref) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Get.get(source_obj, Integer.to_string(i)))
        end)

      list when is_list(list) ->
        Enum.reduce(0..max(length(list) - 1, 0), %{}, fn i, acc ->
          Map.put(acc, Integer.to_string(i), Get.get(source_obj, Integer.to_string(i)))
        end)

      map when is_map(map) ->
        map
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(fn key ->
          String.starts_with?(key, "__") and String.ends_with?(key, "__")
        end)
        |> Enum.reduce(%{}, fn key, acc -> Map.put(acc, key, Get.get(source_obj, key)) end)

      _ ->
        %{}
    end
  end

  def enumerable_string_props(map) when is_map(map), do: map
  def enumerable_string_props(_), do: %{}

  def enumerable_keys({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, proxy_handler() => handler} ->
        own_keys_fn = Get.get(handler, "ownKeys")

        if own_keys_fn != :undefined and own_keys_fn != nil do
          result = Runtime.call_callback(own_keys_fn, [obj])
          Heap.to_list(result) |> Enum.map(&to_string/1)
        else
          []
        end

      {:qb_arr, arr} ->
        numeric_index_keys(:array.size(arr))

      list when is_list(list) ->
        numeric_index_keys(length(list))

      map when is_map(map) ->
        own_keys = enumerable_object_keys(map, ref)
        proto_keys = enumerable_proto_keys(Map.get(map, proto()))
        Runtime.sort_numeric_keys(own_keys ++ Enum.reject(proto_keys, &(&1 in own_keys)))

      _ ->
        []
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

  def enumerable_keys(_), do: []

  def spread_source_to_list({:qb_arr, arr}), do: :array.to_list(arr)
  def spread_source_to_list(list) when is_list(list), do: list

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

  defp enumerable_object_keys(map, ref) do
    raw_keys =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> Map.keys(map)
      end

    raw_keys
    |> Enum.filter(&enumerable_key_candidate?/1)
    |> Enum.reject(fn key -> match?(%{enumerable: false}, Heap.get_prop_desc(ref, key)) end)
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

  defp enumerable_key_candidate?(_), do: false

  defp numeric_index_keys(size) when size <= 0, do: []
  defp numeric_index_keys(size), do: Enum.map(0..(size - 1), &Integer.to_string/1)
end
