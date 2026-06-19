defmodule QuickBEAM.VM.ObjectModel.PrimitiveExoticGet do
  @moduledoc "Primitive wrapper prototype fallback helpers."

  alias QuickBEAM.VM.ObjectModel.{Get, PrototypeLookup}
  alias QuickBEAM.VM.Runtime

  def prototype_property(default_value, key, class_name, receiver) do
    case active_class_proto(class_name) do
      {:obj, _} = proto ->
        case Get.prototype_property_with_receiver(proto, key, receiver) do
          :undefined -> default_or_object_proto(default_value, key)
          value -> value
        end

      _ ->
        default_or_object_proto(default_value, key)
    end
  end

  defp active_class_proto(class_name) do
    case QuickBEAM.VM.GlobalEnvironment.current() do
      %{^class_name => ctor} -> Get.get(ctor, "prototype")
      _ -> Runtime.global_class_proto(class_name)
    end
  end

  defp default_or_object_proto(:undefined, key),
    do: PrototypeLookup.object_prototype_property(:undefined, key)

  defp default_or_object_proto(default_value, _key), do: default_value
end
