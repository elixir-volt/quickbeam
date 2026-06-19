defmodule QuickBEAM.VM.ObjectModel.RegExpExoticGet do
  @moduledoc "RegExp exotic prototype lookup helpers."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.RegExp

  def instance_property({:regexp, _, _, ref}, key) do
    case RegexpState.fetch(ref, proto()) do
      {:ok, instance_proto} ->
        case Get.get(instance_proto, key) do
          :undefined -> prototype_property(key)
          value -> value
        end

      :error ->
        prototype_property(key)
    end
  end

  def prototype_property(key) do
    case active_prototype() do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted do
          :undefined
        else
          proto_property_or_default(proto, key)
        end

      proto ->
        proto_property_or_default(proto, key)
    end
  end

  defp active_prototype do
    case QuickBEAM.VM.GlobalEnvironment.current() do
      %{"RegExp" => ctor} -> Get.get(ctor, "prototype")
      _ -> Runtime.global_class_proto("RegExp")
    end
  end

  defp proto_property_or_default(proto, key) do
    case Get.get(proto, key) do
      :undefined -> RegExp.proto_property(key)
      value -> value
    end
  end
end
