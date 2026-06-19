defmodule QuickBEAM.VM.ObjectModel.OrdinaryGet do
  @moduledoc "Ordinary [[Get]] orchestration for ObjectModel.Get."

  alias QuickBEAM.VM.Heap

  def property(value, key, receiver, callbacks) do
    case own_property_with_receiver(value, key, receiver, callbacks) do
      :undefined -> missing_own_property(value, key, receiver, callbacks)
      {:accessor, getter, _} when getter != nil -> callbacks.call_getter.(getter, receiver)
      {:accessor, nil, _} -> :undefined
      value -> value
    end
  end

  defp own_property_with_receiver({:obj, ref} = value, key, receiver, callbacks) do
    case Heap.get_obj_raw(ref) do
      map when is_map(map) -> map_own_property(value, map, key, receiver, callbacks)
      _ -> callbacks.get_own.(value, key)
    end
  end

  defp own_property_with_receiver(value, key, _receiver, callbacks),
    do: callbacks.get_own.(value, key)

  defp map_own_property(value, map, key, receiver, callbacks) do
    case Map.fetch(map, key) do
      {:ok, {:accessor, getter, _setter}} when getter != nil ->
        callbacks.call_getter.(getter, receiver)

      {:ok, {:accessor, nil, _setter}} ->
        :undefined

      _ ->
        callbacks.get_own.(value, key)
    end
  end

  defp missing_own_property(value, key, receiver, callbacks) do
    if callbacks.explicit_own?.(value, key) do
      :undefined
    else
      if callbacks.prototype_property_with_receiver do
        callbacks.prototype_property_with_receiver.(value, key, receiver)
      else
        value
        |> callbacks.get_prototype_raw.(key)
        |> prototype_result(receiver, callbacks)
      end
    end
  end

  defp prototype_result({:accessor, getter, _}, receiver, callbacks) when getter != nil,
    do: callbacks.call_getter.(getter, receiver)

  defp prototype_result({:accessor, nil, _}, _receiver, _callbacks), do: :undefined
  defp prototype_result(value, _receiver, _callbacks), do: value
end
