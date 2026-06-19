defmodule QuickBEAM.VM.ObjectModel.RawObjectGet do
  @moduledoc "Own-property lookup for raw shape-backed heap objects."

  alias QuickBEAM.VM.Heap

  def own_property(raw, key, callbacks) do
    cond do
      Heap.shape?(raw) and key == "__proto__" ->
        Heap.shape_proto(raw) || :undefined

      Heap.shape?(raw) and key == "length" and callbacks.array_prototype_raw?.(raw) ->
        callbacks.array_prototype_length.() || 0

      Heap.shape?(raw) ->
        case Heap.raw_fetch(raw, key) do
          {:ok, value} -> value
          :error -> callbacks.wrapped_raw_proto_property.(raw, key)
        end

      true ->
        :undefined
    end
  end
end
