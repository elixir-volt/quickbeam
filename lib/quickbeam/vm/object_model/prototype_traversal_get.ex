defmodule QuickBEAM.VM.ObjectModel.PrototypeTraversalGet do
  @moduledoc "Prototype-chain traversal helpers for ObjectModel.Get."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0, proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.ObjectModel.{BuiltinExoticGet, OwnProperty, Prototype, PrototypeLookup}

  def raw_property({:obj, ref}, key, callbacks) do
    case Heap.get_obj_raw(ref) do
      raw when is_tuple(raw) -> raw_tuple_property(ref, raw, key, callbacks)
      map when is_map(map) and is_map_key(map, proto()) -> map_property(ref, map, key, callbacks)
      _ -> callbacks.get_from_prototype.({:obj, ref}, key)
    end
  end

  def raw_property(value, key, callbacks), do: callbacks.get_from_prototype.(value, key)

  def property_with_receiver(target, key, receiver, callbacks) do
    case lookup_with_receiver(target, key, receiver, callbacks) do
      {:found, value} -> value
      {:found_from_accessor, value} -> value
      :not_found -> :undefined
    end
  end

  defp raw_tuple_property(ref, raw, key, callbacks) do
    if Heap.shape?(raw) do
      case Heap.shape_proto(raw) do
        {:obj, _} = proto -> shaped_proto_property(proto, key, {:obj, ref}, callbacks)
        nil -> PrototypeLookup.object_prototype_property({:obj, ref}, key)
        :null_proto -> :undefined
        proto -> callbacks.get_from_prototype.(proto, key)
      end
    else
      callbacks.get_from_prototype.({:obj, ref}, key)
    end
  end

  defp shaped_proto_property(proto, key, receiver, callbacks) do
    case lookup_with_receiver(proto, key, receiver, callbacks) do
      {:found, value} -> value
      :not_found -> PrototypeLookup.object_prototype_property(receiver, key)
    end
  end

  defp map_property(ref, map, key, callbacks) do
    proto = Map.get(map, :__internal_proto__, Map.get(map, proto()))

    type_result =
      case proto do
        {:obj, _} -> lookup_with_receiver(proto, key, {:obj, ref}, callbacks)
        _ -> :not_found
      end
      |> fallback_to_builtin_proto(map, key)

    case type_result do
      {:found, value} -> value
      value when value != :undefined -> value
      _ -> missing_map_proto_property(proto, key, {:obj, ref}, callbacks)
    end
  end

  defp fallback_to_builtin_proto({:found, _} = found, _map, _key), do: found

  defp fallback_to_builtin_proto(_not_found, map, key),
    do: BuiltinExoticGet.map_proto_property(map, key)

  defp missing_map_proto_property({:obj, _} = proto, key, receiver, callbacks),
    do: property_with_receiver(proto, key, receiver, callbacks)

  defp missing_map_proto_property(:null_proto, _key, _receiver, _callbacks), do: :undefined

  defp missing_map_proto_property(proto, key, _receiver, callbacks),
    do: callbacks.get_from_prototype.(proto, key)

  defp lookup_with_receiver(nil, _key, _receiver, _callbacks), do: :not_found

  defp lookup_with_receiver({:obj, ref} = target, key, receiver, callbacks) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => _, proxy_handler() => _} ->
        {:found, callbacks.get.(target, key, receiver)}

      raw ->
        target
        |> descriptor_or_raw_property(raw, key, receiver, callbacks)
        |> continue_with_prototype(target, key, receiver, callbacks)
    end
  end

  defp lookup_with_receiver(target, key, receiver, callbacks) do
    case descriptor_property(target, key, receiver, callbacks) do
      :not_found -> lookup_with_receiver(Prototype.get(target), key, receiver, callbacks)
      found -> found
    end
  end

  defp descriptor_or_raw_property(target, raw, key, receiver, callbacks) do
    case descriptor_property(target, key, receiver, callbacks) do
      {:found_from_accessor, value} ->
        {:found, value}

      _ ->
        case raw_own_property(raw, key) do
          {:ok, {:accessor, getter, _}} when getter != nil ->
            {:found, callbacks.call_getter.(getter, receiver)}

          {:ok, {:accessor, nil, _}} ->
            {:found, :undefined}

          {:ok, value} ->
            {:found, value}

          :error ->
            :not_found
        end
    end
  end

  defp continue_with_prototype(:not_found, target, key, receiver, callbacks) do
    case descriptor_property(target, key, receiver, callbacks) do
      :not_found -> lookup_with_receiver(Prototype.get(target), key, receiver, callbacks)
      {:found_from_accessor, value} -> {:found, value}
      found -> found
    end
  end

  defp continue_with_prototype(found, _target, _key, _receiver, _callbacks), do: found

  defp descriptor_property(target, key, receiver, callbacks) do
    case OwnProperty.descriptor(target, key) do
      {:obj, _} = desc -> descriptor_object_property(desc, receiver, callbacks)
      :undefined -> :not_found
      _ -> :not_found
    end
  end

  defp descriptor_object_property(desc, receiver, callbacks) do
    getter = callbacks.get_own_value.(desc, "get")
    value = callbacks.get_own_value.(desc, "value")

    cond do
      not Value.nullish?(getter) ->
        {:found_from_accessor, callbacks.call_getter.(getter, receiver)}

      value != :undefined ->
        {:found, value}

      true ->
        {:found, :undefined}
    end
  end

  defp raw_own_property(raw, key) when is_map(raw), do: Map.fetch(raw, key)

  defp raw_own_property(raw, key),
    do: if(Heap.shape?(raw), do: Heap.raw_fetch(raw, key), else: :error)
end
