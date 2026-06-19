defmodule QuickBEAM.VM.Runtime.Object.Assign do
  @moduledoc "Implementation helpers for Object.assign."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, PropertyKey, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime.Object.Enumeration

  def assign([target | _sources]) when is_nullish(target) do
    throw({:js_throw, Heap.make_error("Cannot convert undefined or null to object", "TypeError")})
  end

  def assign([target | sources]) do
    target_obj = to_assign_target(target)

    Enum.reduce(sources, target_obj, fn
      source, target_obj when is_nullish(source) ->
        target_obj

      {:obj, _} = source_obj, {:obj, _} = target_obj ->
        source_obj
        |> enumerable_assign_entries()
        |> Enum.each(fn {key, value} -> assign_put(target_obj, key, value) end)

        target_obj

      source, {:obj, _} = target_obj when is_binary(source) ->
        source
        |> Enumeration.string_indexed_entries()
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

  defp assign_put(target_obj, key, value) do
    if InternalMethods.set(target_obj, key, value) do
      :ok
    else
      throw({:js_throw, Heap.make_error("Cannot assign to read only property", "TypeError")})
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

  defp enumerable_assign_entries({:obj, ref} = source_obj) do
    data = Heap.get_obj(ref, %{})

    source_obj
    |> InternalMethods.own_keys()
    |> Enum.filter(
      &(PropertyKey.property_key?(&1) and InternalMethods.enumerable_own_property?(source_obj, &1))
    )
    |> Enum.map(fn key -> {key, Enumeration.enumerable_value(source_obj, data, key)} end)
  end
end
