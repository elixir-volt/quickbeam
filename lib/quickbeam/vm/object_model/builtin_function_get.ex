defmodule QuickBEAM.VM.ObjectModel.BuiltinFunctionGet do
  @moduledoc "Builtin function own-property lookup helpers."

  alias QuickBEAM.VM.{Builtin, Heap}
  alias QuickBEAM.VM.Runtime.{ConstructorProperties, Function}
  alias QuickBEAM.VM.ObjectModel.PrototypeLookup

  def own_property({:builtin, _name, map} = builtin, key, call_getter) when is_map(map) do
    statics = Heap.get_ctor_statics(builtin)

    case Map.fetch(statics, key) do
      {:ok, :deleted} -> :undefined
      {:ok, {:accessor, getter, _}} when getter != nil -> call_getter.(getter, builtin)
      {:ok, {:accessor, nil, _}} -> :undefined
      {:ok, val} -> val
      :error -> Map.get(map, key, :undefined)
    end
  end

  def own_property({:builtin, _, _} = builtin, key, call_getter) do
    case static_property(builtin, key) do
      {:accessor, getter, _} when getter != nil -> call_getter.(getter, builtin)
      {:accessor, nil, _} -> :undefined
      :undefined -> function_proto_fallback(builtin, key)
      value -> value
    end
  end

  def static_property({:builtin, _name, _} = builtin, key) do
    statics = Heap.get_ctor_statics(builtin)

    case Map.fetch(statics, key) do
      {:ok, :deleted} -> :undefined
      {:ok, value} -> value
      :error -> default_static_property(builtin, statics, key)
    end
  end

  defp default_static_property(builtin, statics, key) do
    if constructor_metadata?(builtin, statics) do
      ConstructorProperties.static_property(builtin, key)
    else
      builtin_function_property(builtin, key)
    end
  end

  defp constructor_metadata?(builtin, statics) do
    Heap.get_class_proto(builtin) != nil or Map.has_key?(statics, "prototype") or
      Map.has_key?(statics, :__module__)
  end

  defp builtin_function_property({:builtin, name, _}, "name"), do: name

  defp builtin_function_property({:builtin, _, _} = builtin, "length"),
    do: Builtin.declared_length(builtin)

  defp builtin_function_property(_builtin, _key), do: :undefined

  defp function_proto_fallback(builtin, key) do
    if PrototypeLookup.function_prototype_has_own?(key) do
      :undefined
    else
      PrototypeLookup.fallback_to_object_proto(
        Function.proto_property(builtin, key),
        builtin,
        key
      )
    end
  end
end
