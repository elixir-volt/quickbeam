defmodule QuickBEAM.VM.Runtime.Construction do
  @moduledoc "Helpers for invoking globally registered constructors from host/runtime code."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.ConstructorRegistry

  @doc "Invokes a global constructor and falls back when it is not available."
  def construct(name, args, fallback), do: construct(name, args, fallback, & &1)

  @doc "Invokes a global constructor and updates its object map before prototype patching."
  def construct(name, args, fallback, update_object) do
    case ConstructorRegistry.lookup(name) do
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
