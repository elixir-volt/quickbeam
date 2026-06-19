defmodule QuickBEAM.VM.ObjectModel.BuiltinExoticGet do
  @moduledoc "Builtin exotic prototype lookup helpers for object get semantics."

  import QuickBEAM.VM.Heap.Keys, only: [buffer: 0, date_ms: 0, typed_array: 0]

  alias QuickBEAM.VM.Runtime.ArrayBuffer
  alias QuickBEAM.VM.Runtime.Collections
  alias QuickBEAM.VM.Runtime.Date, as: JSDate

  def map_proto_property(map, key) when is_map(map) do
    cond do
      (collection = Collections.proto_property(map, key)) != :not_collection ->
        collection

      Map.has_key?(map, date_ms()) ->
        JSDate.proto_property(key)

      Map.has_key?(map, buffer()) and not Map.has_key?(map, typed_array()) ->
        if Map.get(map, "__array_buffer_kind__") == :shared_array_buffer,
          do: :undefined,
          else: ArrayBuffer.proto_property(key)

      true ->
        :undefined
    end
  end
end
