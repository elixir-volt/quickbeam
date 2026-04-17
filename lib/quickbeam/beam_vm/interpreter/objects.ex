defmodule QuickBEAM.BeamVM.Interpreter.Objects do
  alias QuickBEAM.BeamVM.{Heap, Bytecode}

  def put({:obj, ref} = obj, key, val) do
    map = Heap.get_obj(ref, %{})
    case is_map(map) && Map.get(map, key) do
      {:accessor, _getter, setter} when setter != nil ->
        invoke_setter(setter, val, obj)
      _ ->
        Heap.put_obj(ref, Map.put(map, key, val))
    end
  end
  def put(%Bytecode.Function{} = f, key, val), do: Heap.put_ctor_static(f, key, val)
  def put({:closure, _, %Bytecode.Function{}} = c, key, val), do: Heap.put_ctor_static(c, key, val)
  def put(_, _, _), do: :ok

  def put_getter({:obj, ref}, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc = case Map.get(map, key) do
        {:accessor, _get, set} -> {:accessor, fun, set}
        _ -> {:accessor, fun, nil}
      end
      Map.put(map, key, desc)
    end)
  end
  def put_getter(target, key, fun), do: Heap.put_ctor_static(target, key, {:accessor, fun, nil})

  def put_setter({:obj, ref}, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc = case Map.get(map, key) do
        {:accessor, get, _set} -> {:accessor, get, fun}
        _ -> {:accessor, nil, fun}
      end
      Map.put(map, key, desc)
    end)
  end
  def put_setter(target, key, fun), do: Heap.put_ctor_static(target, key, {:accessor, nil, fun})

  defp invoke_setter(fun, val, this_obj) do
    alias QuickBEAM.BeamVM.{Bytecode, Interpreter.Ctx}
    ctx = Heap.get_ctx() || %Ctx{}
    Heap.put_ctx(%{ctx | this: this_obj})
    case fun do
      %Bytecode.Function{} = f -> QuickBEAM.BeamVM.Interpreter.invoke(f, [val], 10_000_000)
      {:closure, _, %Bytecode.Function{}} = c -> QuickBEAM.BeamVM.Interpreter.invoke(c, [val], 10_000_000)
      cb when is_function(cb, 1) -> cb.(val)
      _ -> :ok
    end
  end

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
