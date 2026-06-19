defmodule QuickBEAM.VM.Runtime.Globals.GlobalThis do
  @moduledoc "Copies global bindings onto the globalThis object and records their descriptors."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor

  @doc "Copies global bindings onto globalThis, preserving existing globalThis fields."
  def install(%{"globalThis" => {:obj, ref}} = bindings) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        globals = Map.put(bindings, "globalThis", {:obj, ref})
        Heap.put_obj(ref, Map.merge(globals, map))
        install_property_descriptors(ref, globals)

      _ ->
        :ok
    end
  end

  def install(_bindings), do: :ok

  defp install_property_descriptors(ref, globals) do
    Enum.each(globals, fn
      {key, {:builtin, _, _}} ->
        Heap.put_prop_desc(ref, key, PropertyDescriptor.method())

      {key, _value} when key in ["NaN", "Infinity", "undefined"] ->
        Heap.put_prop_desc(ref, key, PropertyDescriptor.prototype())

      {"globalThis", _value} ->
        Heap.put_prop_desc(ref, "globalThis", PropertyDescriptor.method())

      {_key, _value} ->
        :ok
    end)
  end
end
