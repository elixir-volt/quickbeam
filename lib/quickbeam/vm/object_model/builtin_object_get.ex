defmodule QuickBEAM.VM.ObjectModel.BuiltinObjectGet do
  @moduledoc "Own-property lookup for map-backed builtin object shapes such as Date and ArrayBuffer."

  import QuickBEAM.VM.Heap.Keys, only: [buffer: 0, date_ms: 0]

  alias QuickBEAM.VM.ObjectModel.DateExoticGet
  alias QuickBEAM.VM.Runtime.ArrayBuffer

  def date_map?(%{date_ms() => _}), do: true
  def date_map?(_), do: false

  def buffer_map?(%{buffer() => _}), do: true
  def buffer_map?(_), do: false

  def date_property(map, key, callbacks) do
    case callbacks.get_map_property.(map, key) do
      :undefined -> DateExoticGet.proto_property(map, key)
      value -> value
    end
  end

  def buffer_property(map, key) do
    case Map.get(map, key) do
      nil ->
        if Map.get(map, "__array_buffer_kind__") == :shared_array_buffer,
          do: :undefined,
          else: ArrayBuffer.proto_property(key)

      value ->
        value
    end
  end
end
