defmodule QuickBEAM.VM.Runtime.ConstructorRegistry do
  @moduledoc "Helpers for looking up and invoking globally registered JS constructors."

  alias QuickBEAM.VM.{Heap, Runtime}

  @doc "Registers a constructor without creating a prototype."
  def register(name, constructor), do: register(name, constructor, [])

  @doc "Associates a constructor with its class prototype and static `prototype` property."
  def put_prototype(ctor, proto) do
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end

  @doc "Registers a constructor using options such as `:module`, `:prototype`, and `:auto_proto`."
  def register(name, constructor, opts) when is_list(opts) do
    ctor = {:builtin, name, constructor}

    opts
    |> Keyword.get(:module)
    |> put_module_static(ctor)

    case Keyword.get(opts, :prototype) do
      nil ->
        if Keyword.get(opts, :auto_proto, false) do
          register_proto(
            ctor,
            %{},
            Keyword.get(opts, :prototype_parent, Heap.get_object_prototype())
          )
        end

      proto ->
        put_prototype(ctor, proto)
    end

    ctor
  end

  @doc "Registers a constructor with a freshly wrapped prototype map and optional parent prototype."
  def register(name, constructor, proto_properties, parent) when is_map(proto_properties) do
    ctor = {:builtin, name, constructor}
    register_proto(ctor, proto_properties, parent)
    ctor
  end

  defp register_proto(ctor, proto_properties, parent) do
    proto =
      proto_properties
      |> Map.put("constructor", ctor)
      |> QuickBEAM.VM.Builtin.put_if_present("__proto__", parent)
      |> Heap.wrap()

    put_prototype(ctor, proto)
  end

  defp put_module_static(nil, _ctor), do: :ok
  defp put_module_static(module, ctor), do: Heap.put_ctor_static(ctor, :__module__, module)

  @doc "Looks up a constructor by JavaScript global name."
  def lookup(name) do
    case Map.get(Runtime.global_bindings(), name) do
      {:builtin, _, _} = ctor -> ctor
      _ -> nil
    end
  end

  @doc "Returns the class prototype for the globally registered constructor `name`."
  def class_proto(name) do
    case lookup(name) do
      nil -> nil
      ctor -> Heap.get_class_proto(ctor)
    end
  end

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

  @doc "Invokes a global constructor and falls back when it is not available."
  def construct(name, args, fallback), do: construct(name, args, fallback, & &1)

  @doc "Invokes a global constructor and updates its object map before prototype patching."
  def construct(name, args, fallback, update_object) do
    case lookup(name) do
      {:builtin, _, cb} = ctor when is_function(cb, 2) ->
        cb.(args, nil)
        |> update_constructed_object(ctor, update_object)

      _ ->
        fallback.()
    end
  end

  defp update_constructed_object({:obj, ref} = result, ctor, update_object) do
    proto = Heap.get_class_proto(ctor)

    Heap.update_obj(ref, %{}, fn
      map when is_map(map) ->
        map
        |> update_constructed_map(ref, update_object)
        |> put_proto_if_missing(proto)

      other ->
        other
    end)

    result
  end

  defp update_constructed_object(result, _ctor, _update_object), do: result

  defp update_constructed_map(map, _ref, update_object) when is_function(update_object, 1),
    do: update_object.(map)

  defp update_constructed_map(map, ref, update_object) when is_function(update_object, 2),
    do: update_object.(map, ref)

  defp put_proto_if_missing(map, nil), do: map
  defp put_proto_if_missing(map, proto), do: Map.put_new(map, "__proto__", proto)

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
    case lookup(name) do
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
