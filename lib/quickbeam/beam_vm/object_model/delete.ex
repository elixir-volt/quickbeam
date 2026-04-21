defmodule QuickBEAM.BeamVM.ObjectModel.Delete do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  def delete_property(nil, key) do
    throw(
      {:js_throw,
       Heap.make_error("Cannot delete properties of null (deleting '#{key}')", "TypeError")}
    )
  end

  def delete_property(:undefined, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot delete properties of undefined (deleting '#{key}')",
         "TypeError"
       )}
    )
  end

  def delete_property({:obj, ref}, key) do
    map = Heap.get_obj(ref, %{})

    if is_map(map) do
      desc = Heap.get_prop_desc(ref, key)

      if match?(%{configurable: false}, desc) do
        false
      else
        Heap.put_obj(ref, Map.delete(map, key))
        true
      end
    else
      true
    end
  end

  def delete_property(_obj, _key), do: true
end
