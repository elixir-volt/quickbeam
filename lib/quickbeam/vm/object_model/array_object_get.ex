defmodule QuickBEAM.VM.ObjectModel.ArrayObjectGet do
  @moduledoc "Own-property lookup for heap-backed array and arguments objects."

  alias QuickBEAM.VM.Execution.ClosureCells
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PropertyKey

  def own_property(ref, array_data, key, callbacks)

  def own_property(ref, array_data, "length", callbacks) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> callbacks.get_own.(array_data, "length")
    end
  end

  def own_property(ref, array_data, key, callbacks) do
    with {:ok, idx} <- PropertyKey.array_index(key),
         len when is_integer(len) <- virtual_array_length(ref),
         true <- idx >= len do
      :undefined
    else
      _ -> own_index_or_named_property(ref, array_data, key, callbacks)
    end
  end

  def target_slot({:obj, target_ref}, key, callbacks) do
    case Heap.get_obj(target_ref, %{}) do
      map when is_map(map) -> Map.get(map, key, :undefined)
      _ -> callbacks.get_own.({:obj, target_ref}, key)
    end
  end

  def target_slot(_target, _key, _callbacks), do: :undefined

  defp own_index_or_named_property(ref, array_data, key, callbacks) do
    case mapped_argument_value(ref, key) do
      {:mapped, value} -> mapped_value(value)
      :not_mapped -> heap_or_array_property(ref, array_data, key, callbacks)
    end
  end

  defp mapped_value(value), do: value

  defp heap_or_array_property(ref, array_data, key, callbacks) do
    case Heap.get_array_prop(ref, key) do
      :undefined -> fallback_array_property(ref, array_data, key, callbacks)
      value -> value
    end
  end

  defp fallback_array_property(ref, array_data, key, callbacks) do
    own_value = callbacks.get_own.(array_data, key)

    if own_value == :undefined and Heap.get_prop_desc(ref, key) == nil do
      callbacks.get_from_prototype.({:obj, ref}, key)
    else
      own_value
    end
  end

  defp virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp mapped_argument_value(ref, key) do
    with {:ok, idx} <- PropertyKey.array_index(key),
         false <- deleted_argument?(ref, idx),
         mapped when is_map(mapped) <- Heap.get_array_prop(ref, "__mapped_arguments__"),
         {:cell, _} = cell <- Map.get(mapped, idx) do
      {:mapped, ClosureCells.read(cell)}
    else
      _ -> :not_mapped
    end
  end

  defp deleted_argument?(ref, idx) do
    case Heap.get_array_prop(ref, "__deleted_args__") do
      %MapSet{} = deleted -> MapSet.member?(deleted, idx)
      _ -> false
    end
  end
end
