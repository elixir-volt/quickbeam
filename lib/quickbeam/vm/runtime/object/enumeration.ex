defmodule QuickBEAM.VM.Runtime.Object.Enumeration do
  @moduledoc "Enumeration operations for Object.keys/values/entries and related helpers."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.{Heap, Runtime, Value}

  alias QuickBEAM.VM.ObjectModel.{
    Get,
    InternalMethods,
    OwnProperty,
    PropertyKey,
    Semantics
  }

  alias QuickBEAM.VM.Runtime.String, as: JSString

  def keys([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def keys([{:obj, ref} | _]) do
    data = Heap.get_obj(ref, %{})

    if is_list(data) or match?({:qb_arr, _}, data) do
      Heap.wrap(enumerable_keys(ref))
    else
      keys_from_map(ref, data)
    end
  end

  def keys([target | _]) do
    if Value.object_like?(target) do
      target
      |> OwnProperty.descriptor_keys()
      |> Enum.filter(&(is_binary(&1) and OwnProperty.enumerable?(target, &1)))
      |> Heap.wrap()
    else
      Heap.wrap([])
    end
  end

  def keys(_), do: Heap.wrap([])

  def own_property_names([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def own_property_names([{:obj, ref} | _]) do
    Heap.wrap(OwnProperty.descriptor_keys({:obj, ref}) |> Enum.filter(&is_binary/1))
  end

  def own_property_names([target | _]) do
    target
    |> OwnProperty.descriptor_keys()
    |> Enum.filter(&is_binary/1)
    |> Heap.wrap()
  end

  def own_property_names(_), do: Heap.wrap([])

  def values([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def values([{:obj, _ref} = obj | _]) do
    obj
    |> InternalMethods.own_keys()
    |> Enum.filter(&(is_binary(&1) and InternalMethods.enumerable_own_property?(obj, &1)))
    |> Enum.map(&Get.get(obj, &1))
    |> Heap.wrap()
  end

  def values([string | _]) when is_binary(string) do
    string
    |> JSString.utf16_code_units()
    |> Heap.wrap()
  end

  def values([map | _]) when is_map(map), do: Map.values(map)
  def values(_), do: []

  def entries([target | _]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def entries([{:obj, _ref} = obj | _]) do
    keys = obj |> InternalMethods.own_keys() |> Enum.filter(&is_binary/1)
    Heap.wrap(enumerable_descriptor_pairs(obj, keys))
  end

  def entries([callable | _]) when is_tuple(callable) or is_struct(callable) do
    keys = callable |> InternalMethods.own_keys() |> Enum.filter(&is_binary/1)
    Heap.wrap(enumerable_descriptor_pairs(callable, keys))
  end

  def entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {key, value} -> [key, value] end)
  end

  def entries([string | _]) when is_binary(string) do
    string
    |> string_indexed_entries()
    |> Enum.map(fn {index, char} -> Heap.wrap([index, char]) end)
    |> Heap.wrap()
  end

  def entries(_), do: []

  def enumerable_keys(ref) do
    data = Heap.get_obj(ref, %{})

    case data do
      {:qb_arr, arr} ->
        Semantics.enumerable_array_keys(ref, arr, array_prop_keys(ref))

      list when is_list(list) ->
        (array_indices(list) ++ array_prop_keys(ref)) |> Runtime.sort_numeric_keys()

      map when is_map(map) and is_map_key(map, proxy_target()) ->
        {:obj, ref}
        |> OwnProperty.descriptor_keys()
        |> Enum.filter(
          &(is_binary(&1) and InternalMethods.enumerable_own_property?({:obj, ref}, &1))
        )

      map when is_map(map) ->
        map
        |> enumerable_key_pairs()
        |> Enum.map(fn {key, _raw_key} -> key end)
        |> Runtime.sort_numeric_keys()
        |> Enum.filter(fn key -> enumerable_object_key?(ref, map, key) end)

      _ ->
        []
    end
  end

  def enumerable_value(obj, map, key) when is_map(map) do
    raw_key = integer_property_key(key)

    cond do
      match?({:accessor, _, _}, Map.get(map, key)) -> Get.get(obj, key)
      Map.has_key?(map, key) -> Map.get(map, key)
      raw_key != :error and match?({:accessor, _, _}, Map.get(map, raw_key)) -> Get.get(obj, key)
      raw_key != :error and Map.has_key?(map, raw_key) -> Map.get(map, raw_key)
      true -> Get.get(obj, key)
    end
  end

  def enumerable_value(obj, _data, key), do: Get.get(obj, key)

  def enumerable_descriptor_pairs(target, keys) do
    keys
    |> Enum.filter(&InternalMethods.enumerable_own_property?(target, &1))
    |> Enum.map(&Heap.wrap([&1, Get.get(target, &1)]))
  end

  def string_indexed_entries(string), do: JSString.utf16_indexed_entries(string)

  defp keys_from_map(_ref, {:qb_arr, arr}) do
    for i <- 0..(:array.size(arr) - 1), do: Integer.to_string(i)
  end

  defp keys_from_map(_ref, list) when is_list(list), do: Heap.wrap(array_indices(list))
  defp keys_from_map(ref, map) when is_map(map), do: Heap.wrap(enumerable_keys(ref))

  defp array_prop_keys(ref) do
    ref
    |> Heap.get_array_props()
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_binary(key) and not internal?(key) and
        not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
    end)
  end

  defp enumerable_key_pairs(map) do
    raw =
      case Map.get(map, key_order()) do
        order when is_list(order) -> Enum.reverse(order)
        _ -> []
      end

    raw = raw ++ (Map.keys(map) -- raw)

    Enum.flat_map(raw, fn
      key when is_binary(key) -> [{key, key}]
      key when is_integer(key) and key >= 0 -> [{Integer.to_string(key), key}]
      _ -> []
    end)
  end

  defp enumerable_object_key?(ref, map, key) do
    raw_key = if Map.has_key?(map, key), do: key, else: integer_property_key(key)
    raw_key = if raw_key != :error and Map.has_key?(map, raw_key), do: raw_key, else: key

    is_binary(key) and not internal_namespace?(key) and Map.has_key?(map, raw_key) and
      not match?(%{enumerable: false}, Heap.get_prop_desc(ref, raw_key))
  end

  defp integer_property_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> :error
    end
  end

  defp array_indices(list) do
    list |> Enum.with_index() |> Enum.map(fn {_, index} -> Integer.to_string(index) end)
  end
end
