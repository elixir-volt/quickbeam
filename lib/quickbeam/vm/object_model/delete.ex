defmodule QuickBEAM.VM.ObjectModel.Delete do
  @moduledoc "Implements JavaScript [[Delete]] semantics for VM values."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values

  @doc "Deletes a property according to JavaScript delete semantics."
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
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        desc = Heap.get_prop_desc(ref, key)

        if match?(%{configurable: false}, desc) do
          false
        else
          Heap.put_obj(ref, Map.delete(map, key))
          true
        end

      {:qb_arr, _} ->
        delete_array_property(ref, key)

      list when is_list(list) ->
        delete_array_property(ref, key)

      _ ->
        true
    end
  end

  def delete_property(_obj, _key), do: true

  defp delete_array_property(_ref, "length"), do: false

  defp delete_array_property(ref, key) do
    key = if is_binary(key), do: key, else: Values.stringify(key)

    case Integer.parse(key) do
      {idx, ""} when idx >= 0 ->
        Heap.array_set(ref, idx, :undefined)
        true

      _ ->
        true
    end
  end
end
