defmodule QuickBEAM.VM.ObjectModel.DateExoticGet do
  @moduledoc "Date exotic property lookup helpers."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Date, as: JSDate

  def proto_property(map, key) do
    case Map.get(map, proto()) do
      {:obj, _} = proto ->
        case Get.get(proto, key) do
          :undefined -> JSDate.proto_property(key)
          val -> val
        end

      _ ->
        JSDate.proto_property(key)
    end
  end
end
