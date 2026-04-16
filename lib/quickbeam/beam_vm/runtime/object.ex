defmodule QuickBEAM.BeamVM.Runtime.Object do
  alias QuickBEAM.BeamVM.Heap
  @moduledoc "Object static methods."

  alias QuickBEAM.BeamVM.Runtime

  def static_property("keys"), do: {:builtin, "keys", fn args -> keys(args) end}
  def static_property("values"), do: {:builtin, "values", fn args -> values(args) end}
  def static_property("entries"), do: {:builtin, "entries", fn args -> entries(args) end}
  def static_property("assign"), do: {:builtin, "assign", fn args -> assign(args) end}
  def static_property("freeze"), do: {:builtin, "freeze", fn [obj | _] -> obj end}
  def static_property("is"), do: {:builtin, "is", fn [a, b | _] -> Runtime.js_strict_eq(a, b) end}
  def static_property("create"), do: {:builtin, "create", fn _ -> Runtime.obj_new() end}
  def static_property("defineProperty"), do: {:builtin, "defineProperty", fn args -> define_property(args) end}
  def static_property("getOwnPropertyNames"), do: {:builtin, "getOwnPropertyNames", fn args -> keys(args) end}
  def static_property(_), do: :undefined

  defp keys([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    Map.keys(map) |> Enum.reject(&String.starts_with?(&1, "__"))
  end
  defp keys([map | _]) when is_map(map), do: Map.keys(map)
  defp keys(_), do: []

  defp values([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    Map.values(map)
  end
  defp values([map | _]) when is_map(map), do: Map.values(map)
  defp values(_), do: []

  defp entries([{:obj, ref} | _]) do
    map = Heap.get_obj(ref, %{})
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end
  defp entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end
  defp entries(_), do: []

  defp assign([target | sources]) do
    Enum.reduce(sources, target, fn
      {:obj, ref}, {:obj, tref} ->
        src_map = Heap.get_obj(ref, %{})
        tgt_map = Heap.get_obj(tref, %{})
        Heap.put_obj(tref, Map.merge(tgt_map, src_map))
        {:obj, tref}
      map, {:obj, tref} when is_map(map) ->
        tgt_map = Heap.get_obj(tref, %{})
        Heap.put_obj(tref, Map.merge(tgt_map, map))
        {:obj, tref}
      _, acc -> acc
    end)
  end
  defp define_property([{:obj, ref} = obj, key, {:obj, desc_ref} | _]) do
    desc = Heap.get_obj(desc_ref, %{})
    prop_name = if is_binary(key), do: key, else: to_string(key)
    existing = Heap.get_obj(ref, %{})
    val = Map.get(desc, "value", Map.get(existing, prop_name, :undefined))
    Heap.put_obj(ref, Map.put(existing, prop_name, val))
    obj
  end
  defp define_property([obj | _]), do: obj
end
