defmodule QuickBEAM.VM.ObjectModel.TypedArrayObjectGet do
  @moduledoc "Own-property lookup for heap-backed typed array objects."

  import QuickBEAM.VM.Heap.Keys, only: [typed_array: 0]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.TypedArrayExoticGet
  alias QuickBEAM.VM.Runtime.TypedArray

  def typed_array_map?(%{typed_array() => true}), do: true
  def typed_array_map?(_), do: false

  def own_property(obj, map, key, callbacks)

  def own_property({:obj, ref} = obj, map, "length" = key, callbacks) do
    if Heap.get_prop_desc(ref, key) do
      callbacks.get_map_property.(map, key, obj)
    else
      if(TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.element_count(obj))
    end
  end

  def own_property({:obj, ref} = obj, map, "byteLength" = key, callbacks) do
    if Heap.get_prop_desc(ref, key) do
      callbacks.get_map_property.(map, key, obj)
    else
      if(TypedArray.out_of_bounds?(obj), do: 0, else: TypedArray.current_byte_length(obj))
    end
  end

  def own_property({:obj, ref} = obj, map, "byteOffset" = key, callbacks) do
    if Heap.get_prop_desc(ref, key) do
      callbacks.get_map_property.(map, key, obj)
    else
      if(TypedArray.out_of_bounds?(obj), do: 0, else: Map.get(map, "byteOffset", 0))
    end
  end

  def own_property(obj, map, key, callbacks),
    do:
      TypedArrayExoticGet.property(obj, map, key, fn ->
        callbacks.get_map_property.(map, key, obj)
      end)
end
