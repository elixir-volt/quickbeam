defmodule QuickBEAM.VM.ObjectModel.ArrayExoticGet do
  @moduledoc "Array exotic prototype lookup helpers for property get semantics."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Array

  def proto_property({:obj, ref}, key) do
    case Heap.get_array_proto(ref) do
      {:obj, _} = proto ->
        case Get.get(proto, key) do
          :undefined -> receiver_array_proto_fallback(proto, key)
          val -> val
        end

      _ ->
        Array.proto_property(key)
    end
  end

  def proto_property(key) do
    case Heap.get_array_proto() do
      {:obj, _} = proto ->
        case Get.get(proto, key) do
          :undefined -> fallback_array_proto_property(proto, key)
          val -> val
        end

      _ ->
        Array.proto_property(key)
    end
  end

  defp receiver_array_proto_fallback(proto, key) do
    if proto == Heap.get_array_proto() do
      fallback_array_proto_property(proto, key)
    else
      :undefined
    end
  end

  defp fallback_array_proto_property(proto, key) do
    case Array.proto_property(key) do
      :undefined -> default_object_prototype(proto, key)
      val -> val
    end
  end

  defp default_object_prototype(obj, key) do
    proto = Heap.get_object_prototype() || QuickBEAM.VM.Runtime.Object.build_prototype()

    case proto do
      {:obj, _} = proto when proto != obj -> Get.get(proto, key)
      _ -> :undefined
    end
  end
end
