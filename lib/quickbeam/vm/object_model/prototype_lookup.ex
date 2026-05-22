defmodule QuickBEAM.VM.ObjectModel.PrototypeLookup do
  @moduledoc "Shared prototype fallback lookup helpers."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Object

  def function_prototype_has_own?(key) do
    case Heap.get_func_proto() do
      {:obj, ref} -> match?({:ok, _}, Heap.raw_fetch(Heap.get_obj_raw(ref), key))
      _ -> false
    end
  end

  def object_prototype_property(obj, key) do
    proto = Heap.get_object_prototype() || Object.build_prototype()

    case proto do
      {:obj, _} = proto when proto != obj -> Get.get(proto, key)
      _ -> :undefined
    end
  end

  def fallback_to_object_proto(:undefined, obj, key), do: object_prototype_property(obj, key)
  def fallback_to_object_proto(value, _obj, _key), do: value
end
