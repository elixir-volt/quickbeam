defmodule QuickBEAM.VM.Runtime.ConstructorProperties do
  @moduledoc "Static property and metadata fallback semantics for builtin constructors."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.ConstructorRegistry

  @doc "Ensures process-local metadata for a builtin constructor is available."
  def ensure_builtin_metadata({:builtin, name, _} = ctor) do
    current_statics = Heap.get_ctor_statics(ctor)
    current_proto = Heap.get_class_proto(ctor)

    if current_statics == %{} or current_proto == nil do
      copy_registered_metadata(name, ctor, current_statics, current_proto)
    end

    ctor
  end

  def ensure_builtin_metadata(ctor), do: ctor

  @doc "Returns a builtin constructor's own static property without invoking accessors."
  def static_property({:builtin, name, _} = ctor, key) do
    ensure_builtin_metadata(ctor)
    statics = Heap.get_ctor_statics(ctor)

    case Map.fetch(statics, key) do
      {:ok, :deleted} -> :undefined
      {:ok, value} -> value
      :error -> fallback_static_property(ctor, name, key, statics)
    end
  end

  def static_property(_, _), do: :undefined

  @doc "Returns a builtin constructor's prototype object, installing intrinsic metadata if needed."
  def builtin_prototype({:builtin, _, _} = ctor), do: static_property(ctor, "prototype")
  def builtin_prototype(_), do: nil

  defp fallback_static_property(ctor, _name, "prototype", _statics) do
    case constructor_prototype(ctor) do
      :deleted -> :undefined
      nil -> :undefined
      value -> value
    end
  end

  defp fallback_static_property(_ctor, name, "name", _statics), do: name

  defp fallback_static_property(ctor, _name, "length", _statics),
    do: QuickBEAM.VM.Builtin.declared_length(ctor)

  defp fallback_static_property(ctor, name, key, statics) do
    module_static_property(Map.get(statics, :__module__), name, ctor, key)
  end

  defp module_static_property(module, name, ctor, key) when is_atom(module) do
    cond do
      function_exported?(module, :constructor_static_property, 3) ->
        module.constructor_static_property(name, ctor, key)

      function_exported?(module, :static_property, 1) ->
        module.static_property(key)

      true ->
        :undefined
    end
  end

  defp module_static_property(_, _, _, _), do: :undefined

  defp constructor_prototype(ctor) do
    case Heap.get_ctor_statics(ctor) do
      %{"prototype" => :deleted} -> :deleted
      %{"prototype" => {:obj, _} = proto} -> proto
      _ -> Heap.get_class_proto(ctor)
    end
  end

  defp copy_registered_metadata(name, ctor, current_statics, current_proto) do
    case registered_constructor(name) do
      {:builtin, ^name, _} = registered ->
        registered_statics = Heap.get_ctor_statics(registered)

        if current_statics == %{} and registered_statics != %{} do
          Heap.put_ctor_statics(ctor, Map.merge(registered_statics, current_statics))
        end

        if current_proto == nil do
          case constructor_prototype(registered) do
            {:obj, _} = proto -> Heap.put_class_proto(ctor, proto)
            _ -> :ok
          end
        end

      _ ->
        :ok
    end
  end

  defp registered_constructor(name) do
    case ConstructorRegistry.lookup(name) do
      {:builtin, ^name, _} = ctor ->
        if Heap.get_ctor_statics(ctor) == %{} and Heap.get_class_proto(ctor) == nil do
          Map.get(QuickBEAM.VM.Runtime.Globals.Builder.build(), name)
        else
          ctor
        end

      _ ->
        Map.get(QuickBEAM.VM.Runtime.Globals.Builder.build(), name)
    end
  end
end
