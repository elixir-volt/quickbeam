defmodule QuickBEAM.VM.Runtime.Constructors do
  @moduledoc "Helpers for looking up and invoking globally registered JS constructors."

  alias QuickBEAM.VM.{Heap, Runtime}

  def register(name, constructor), do: register(name, constructor, [])

  def put_prototype(ctor, proto) do
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end

  def register(name, constructor, opts) when is_list(opts) do
    ctor = {:builtin, name, constructor}

    opts
    |> Keyword.get(:module)
    |> put_module_static(ctor)

    case Keyword.get(opts, :prototype) do
      nil ->
        if Keyword.get(opts, :auto_proto, false) do
          register_proto(ctor, %{}, nil)
        end

      proto ->
        put_prototype(ctor, proto)
    end

    ctor
  end

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

  def lookup(name) do
    case Map.get(Runtime.global_bindings(), name) do
      {:builtin, _, _} = ctor -> ctor
      _ -> nil
    end
  end

  def class_proto(name) do
    case lookup(name) do
      nil -> nil
      ctor -> Heap.get_class_proto(ctor)
    end
  end

  def construct(name, args, fallback), do: construct(name, args, fallback, & &1)

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
end
