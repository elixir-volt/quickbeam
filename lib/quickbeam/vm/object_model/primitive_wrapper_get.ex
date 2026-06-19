defmodule QuickBEAM.VM.ObjectModel.PrimitiveWrapperGet do
  @moduledoc "Property lookup helpers for boxed primitive objects and primitive prototype fallbacks."

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyKey, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime.{Boolean, Number}
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.String, as: JSString

  def raw_length(raw) do
    case Heap.raw_fetch(raw, WrappedPrimitive.slot(:string)) do
      {:ok, value} when is_binary(value) -> JSString.utf16_length(value)
      _ -> :undefined
    end
  end

  def map_length(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, value} -> JSString.utf16_length(value)
      :error -> :undefined
    end
  end

  def raw_proto_property(raw, key) do
    cond do
      match?({:ok, _}, Heap.raw_fetch(raw, WrappedPrimitive.slot(:number))) ->
        number_proto_property(key)

      match?({:ok, _}, Heap.raw_fetch(raw, WrappedPrimitive.slot(:string))) ->
        {:ok, string} = Heap.raw_fetch(raw, WrappedPrimitive.slot(:string))
        string_property(string, key)

      match?({:ok, _}, Heap.raw_fetch(raw, WrappedPrimitive.slot(:boolean))) ->
        boolean_proto_property(Heap.shape_to_map(raw), key)

      true ->
        :undefined
    end
  end

  def map_proto_property(map, key) do
    case WrappedPrimitive.type(map) do
      :symbol ->
        {:ok, value} = WrappedPrimitive.value(map, :symbol)
        Get.get(value, key)

      :number ->
        number_proto_property(key)

      :string ->
        {:ok, value} = WrappedPrimitive.value(map, :string)
        string_property(value, key)

      :boolean ->
        boolean_proto_property(map, key)

      :bigint ->
        {:ok, value} = WrappedPrimitive.value(map, :bigint)
        Get.get(value, key)

      _ ->
        :undefined
    end
  end

  def number_proto_property(key) do
    case Runtime.global_class_proto("Number") do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted,
          do: default_object_prototype(proto, key),
          else: Number.proto_property(key)

      _ ->
        Number.proto_property(key)
    end
  end

  def string_property(string, "length") when is_binary(string), do: JSString.utf16_length(string)

  def string_property(string, key) when is_binary(string) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> JSString.utf16_code_unit_at(string, idx)
      :error -> string_proto_property(key)
    end
  end

  def string_proto_property(key) do
    case Runtime.global_class_proto("String") do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted,
          do: default_object_prototype(proto, key),
          else: JSString.proto_property(key)

      _ ->
        JSString.proto_property(key)
    end
  end

  def boolean_proto_property(map, key) when is_map(map) do
    case Map.get(map, proto()) do
      {:obj, _} = prototype -> Get.get(prototype, key)
      _ -> boolean_proto_property(key)
    end
  end

  def boolean_proto_property(key) do
    case Runtime.global_class_proto("Boolean") do
      {:obj, ref} = proto ->
        if Heap.get_prop_desc(ref, key) == :deleted,
          do: default_object_prototype(proto, key),
          else: Boolean.proto_property(key)

      _ ->
        Boolean.proto_property(key)
    end
  end

  defp default_object_prototype(obj, key) do
    proto = Heap.get_object_prototype() || Object.build_prototype()

    case proto do
      {:obj, _} = proto when proto != obj -> Get.get(proto, key)
      _ -> :undefined
    end
  end
end
