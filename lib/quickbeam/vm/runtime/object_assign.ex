defmodule QuickBEAM.VM.Runtime.ObjectAssign do
  @moduledoc "Implementation helpers for Object.assign."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1, is_symbol: 1]

  alias QuickBEAM.VM.{Heap, Runtime, Value}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, PropertyKey, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime.{ObjectDescriptors, ObjectEnumeration}

  def assign([target | _sources]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def assign([target | sources]) do
    target_obj = to_assign_target(target)

    Enum.reduce(sources, target_obj, fn
      source, target_obj when is_nullish(source) ->
        target_obj

      {:obj, ref}, {:obj, _} = target_obj ->
        ref
        |> enumerable_assign_entries()
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      source, {:obj, _} = target_obj when is_binary(source) ->
        source
        |> ObjectEnumeration.string_indexed_entries()
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      map, {:obj, _} = target_obj when is_map(map) ->
        map
        |> Enum.reject(fn {key, _value} -> internal_slot?(key) end)
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      _, acc ->
        acc
    end)
  end

  def assign(_), do: :undefined

  defp assign_put({:obj, ref} = target_obj, key, value) do
    cond do
      target_accessor_setter?(ref, key) ->
        InternalMethods.set(target_obj, key, value)

      target_readonly?(ref, key) or target_string_index?(ref, key) ->
        throw({:js_throw, Heap.make_error("Cannot assign to read only property", "TypeError")})

      not target_has_own?(ref, key) and not Heap.extensible?(ref) ->
        throw({:js_throw, Heap.make_error("Cannot add property", "TypeError")})

      true ->
        InternalMethods.set(target_obj, key, value)
    end
  end

  defp target_accessor_setter?(ref, key) do
    case target_own_value(ref, key) do
      {:accessor, _, setter} when setter != nil -> true
      _ -> false
    end
  end

  defp target_readonly?(ref, key), do: match?(%{writable: false}, Heap.get_prop_desc(ref, key))

  defp target_string_index?(ref, key) do
    case Heap.get_obj_raw(ref) do
      map when is_map(map) and is_binary(key) ->
        with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(map, :string),
             {:ok, index} <- PropertyKey.array_index(key) do
          index < Get.string_length(string)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp target_has_own?(ref, key), do: target_own_value(ref, key) != :missing

  defp target_own_value(ref, key) do
    case Heap.raw_fetch(Heap.get_obj_raw(ref), key) do
      {:ok, value} -> value
      :error -> :missing
    end
  end

  defp to_assign_target({:obj, _} = object), do: object
  defp to_assign_target(target), do: object_value_of(target)

  defp object_value_of(value) when is_nullish(value) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  defp object_value_of({:obj, _} = obj), do: obj
  defp object_value_of(value) when is_binary(value), do: WrappedPrimitive.wrap(value)
  defp object_value_of(value) when is_number(value), do: WrappedPrimitive.wrap(value)
  defp object_value_of(value) when is_boolean(value), do: WrappedPrimitive.wrap(value)
  defp object_value_of({:symbol, _, _} = value), do: WrappedPrimitive.wrap(value)
  defp object_value_of({:symbol, _} = value), do: WrappedPrimitive.wrap(value)
  defp object_value_of(value), do: value

  defp enumerable_assign_entries(ref) do
    data = Heap.get_obj(ref, %{})

    if is_map(data) and Map.has_key?(data, proxy_target()) do
      proxy_assign_entries({:obj, ref}, data)
    else
      (ObjectEnumeration.enumerable_keys(ref) ++ enumerable_symbol_keys(ref, data))
      |> Enum.map(fn key -> {key, ObjectEnumeration.enumerable_value({:obj, ref}, data, key)} end)
    end
  end

  defp proxy_assign_entries(source_obj, %{proxy_target() => target, proxy_handler() => handler}) do
    keys =
      case Get.get(handler, "ownKeys") do
        trap when not is_nullish(trap) ->
          trap |> Runtime.call_callback([target]) |> Heap.to_list()

        _ ->
          ObjectEnumeration.enumerable_keys(elem(target, 1))
      end

    descriptor_trap = Get.get(handler, "getOwnPropertyDescriptor")

    keys
    |> Enum.filter(fn key ->
      PropertyKey.property_key?(key) and proxy_assign_enumerable?(target, descriptor_trap, key)
    end)
    |> Enum.map(fn key -> {key, Get.get(source_obj, key)} end)
  end

  defp proxy_assign_enumerable?(target, descriptor_trap, key) do
    descriptor =
      if not Value.nullish?(descriptor_trap) do
        Runtime.call_callback(descriptor_trap, [target, key])
      else
        ObjectDescriptors.own_property_descriptor([target, key])
      end

    descriptor != :undefined and Get.get(descriptor, "enumerable") == true
  end

  defp enumerable_symbol_keys(ref, data) when is_map(data) do
    data
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_symbol(key) and not match?(%{enumerable: false}, Heap.get_prop_desc(ref, key))
    end)
  end

  defp enumerable_symbol_keys(_ref, _data), do: []
end
