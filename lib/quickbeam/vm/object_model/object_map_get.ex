defmodule QuickBEAM.VM.ObjectModel.ObjectMapGet do
  @moduledoc "Own-property lookup for ordinary map-backed heap objects."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PrimitiveWrapperGet
  alias QuickBEAM.VM.ObjectModel.Semantics
  alias QuickBEAM.VM.ObjectModel.WrappedPrimitive
  alias QuickBEAM.VM.Runtime.Date, as: JSDate

  def own_property(ref, map, "length", callbacks) do
    if Semantics.array_prototype_object?(map) do
      callbacks.array_prototype_length.() || 0
    else
      prototype_or_wrapped_property(map, "length", {:obj, ref}, callbacks)
    end
  end

  def own_property(ref, map, key, callbacks) do
    cond do
      Heap.get_prop_desc(ref, key) == :deleted ->
        :undefined

      key == "__proto__" and Map.has_key?(map, :__internal_proto__) and Map.has_key?(map, key) ->
        callbacks.get_map_property.(map, key, {:obj, ref})

      true ->
        prototype_or_wrapped_property(map, key, {:obj, ref}, callbacks)
    end
  end

  defp prototype_or_wrapped_property(map, key, receiver, callbacks) do
    case prototype_object_property(map, key) do
      :undefined -> wrapped_or_map_property(map, key, receiver, callbacks)
      value -> value
    end
  end

  defp prototype_object_property(%{"constructor" => {:builtin, "Date", _}}, key),
    do: JSDate.proto_property(key)

  defp prototype_object_property(_map, _key), do: :undefined

  defp wrapped_or_map_property(map, key, receiver, callbacks) do
    if WrappedPrimitive.type(map) in [:string, :number, :boolean] and Map.has_key?(map, key) do
      callbacks.get_map_property.(map, key, receiver)
    else
      case PrimitiveWrapperGet.map_proto_property(map, key) do
        :undefined -> callbacks.get_map_property.(map, key, receiver)
        value -> value
      end
    end
  end
end
