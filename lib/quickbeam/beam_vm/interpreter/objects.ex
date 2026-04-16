defmodule QuickBEAM.BeamVM.Interpreter.Objects do
  alias QuickBEAM.BeamVM.Heap

  def put({:obj, ref}, key, val) do
    Heap.update_obj(ref, %{}, &Map.put(&1, key, val))
  end
  def put(_, _, _), do: :ok

  def has_property({:obj, ref}, key), do: Map.has_key?(Heap.get_obj(ref, %{}), key)
  def has_property(obj, key) when is_map(obj), do: Map.has_key?(obj, key)
  def has_property(obj, key) when is_list(obj) and is_integer(key), do: key >= 0 and key < length(obj)
  def has_property(_, _), do: false

  def get_array_el({:obj, ref}, idx) do
    case Heap.get_obj(ref) do
      list when is_list(list) and is_integer(idx) -> Enum.at(list, idx, :undefined)
      map when is_map(map) ->
        key = if is_integer(idx), do: Integer.to_string(idx), else: idx
        Map.get(map, key, Map.get(map, idx, :undefined))
      _ -> :undefined
    end
  end
  def get_array_el(obj, idx) when is_list(obj) and is_integer(idx), do: Enum.at(obj, idx, :undefined)
  def get_array_el(obj, idx) when is_map(obj), do: Map.get(obj, idx, :undefined)
  def get_array_el(s, idx) when is_binary(s) and is_integer(idx) and idx >= 0, do: String.at(s, idx) || :undefined
  def get_array_el(_, _), do: :undefined

  def put_array_el({:obj, ref}, key, val) do
    case Heap.get_obj(ref) do
      list when is_list(list) ->
        case key do
          i when is_integer(i) and i >= 0 and i < length(list) ->
            Heap.put_obj(ref, List.replace_at(list, i, val))
          _ -> :ok
        end
      map when is_map(map) ->
        Heap.put_obj(ref, Map.put(map, Kernel.to_string(key), val))
      nil ->
        :ok
    end
  end
  def put_array_el(_, _, _), do: :ok

  def list_set_at(list, i, val) when is_integer(i) and i >= 0 and i < length(list), do: List.replace_at(list, i, val)
  def list_set_at(list, i, val) when is_integer(i) and i >= 0, do: list ++ List.duplicate(:undefined, max(0, i - length(list))) ++ [val]
end
