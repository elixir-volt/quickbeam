defmodule QuickBEAM.VM.ObjectModel.MapPropertyGet do
  @moduledoc "Map-backed property get helpers shared by ordinary object lookup."

  def property(map, key, receiver, call_getter) do
    case Map.fetch(map, key) do
      {:ok, {:accessor, getter, _setter}} when getter != nil -> call_getter.(getter, receiver)
      {:ok, value} -> value
      :error -> :undefined
    end
  end
end
