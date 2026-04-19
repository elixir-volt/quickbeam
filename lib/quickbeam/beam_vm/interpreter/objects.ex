defmodule QuickBEAM.BeamVM.Interpreter.Objects do
  @moduledoc false
  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.{Bytecode, Heap, Runtime}
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.Runtime.Property

  @compile {:inline, has_property: 2, get_element: 2, set_list_at: 3}
  alias QuickBEAM.BeamVM.Interpreter
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.Runtime.Property
  alias QuickBEAM.BeamVM.{Heap, Bytecode, Runtime}

  def put({:obj, ref} = _obj, "length", val) do
    data = Heap.get_obj(ref)

    if is_list(data) do
      new_len = Runtime.to_int(val)
      truncated = Enum.take(data, max(0, new_len))

      padded =
        if new_len > length(truncated),
          do: truncated ++ List.duplicate(:undefined, new_len - length(truncated)),
          else: truncated

      Heap.put_obj(ref, padded)
    end
  end

  def put({:obj, ref} = obj, key, val) do
    key = normalize_key(key)
    map = Heap.get_obj(ref, %{})

    case map do
      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        set_trap = Property.get(handler, "set")

        if set_trap != :undefined do
          # Proxy set trap return value ignored (non-strict mode behavior)
          Runtime.call_callback(set_trap, [target, key, val])
        else
          put(target, key, val)
        end

      _ when is_map(map) ->
        cond do
          Heap.frozen?(ref) ->
            :ok

          match?({:accessor, _, setter} when setter != nil, Map.get(map, key)) ->
            {:accessor, _, setter} = Map.get(map, key)
            invoke_setter(setter, val, obj)

          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            :ok

          true ->
            Heap.put_obj_key(ref, key, val)
        end

      _ ->
        :ok
    end
  end

  def put(%Bytecode.Function{} = f, key, val), do: Heap.put_ctor_static(f, key, val)

  def put({:closure, _, %Bytecode.Function{}} = c, key, val),
    do: Heap.put_ctor_static(c, key, val)

  def put(_, _, _), do: :ok

  defp normalize_key(k) when is_float(k) and k == trunc(k) and k >= 0,
    do: Integer.to_string(trunc(k))

  defp normalize_key(k) when is_float(k), do: Values.stringify(k)
  defp normalize_key(k), do: k

  def put_getter({:obj, ref}, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc =
        case Map.get(map, key) do
          {:accessor, _get, set} -> {:accessor, fun, set}
          _ -> {:accessor, fun, nil}
        end

      Map.put(map, key, desc)
    end)
  end

  def put_getter(target, key, fun), do: Heap.put_ctor_static(target, key, {:accessor, fun, nil})

  def put_setter({:obj, ref}, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc =
        case Map.get(map, key) do
          {:accessor, get, _set} -> {:accessor, get, fun}
          _ -> {:accessor, nil, fun}
        end

      Map.put(map, key, desc)
    end)
  end

  def put_setter(target, key, fun), do: Heap.put_ctor_static(target, key, {:accessor, nil, fun})

  defp invoke_setter(fun, val, this_obj) do
    Interpreter.invoke_with_receiver(fun, [val], Runtime.gas_budget(), this_obj)
  end

  def has_property({:obj, ref}, key) do
    map = Heap.get_obj(ref, %{})

    case map do
      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        has_trap = Property.get(handler, "has")

        if has_trap != :undefined do
          Runtime.call_callback(has_trap, [target, key])
        else
          has_property(target, key)
        end

      _ when is_map(map) ->
        Map.has_key?(map, key)

      _ ->
        false
    end
  end

  def has_property(obj, key) when is_map(obj), do: Map.has_key?(obj, key)

  def has_property(obj, key) when is_list(obj) and is_integer(key),
    do: key >= 0 and key < length(obj)

  def has_property(_, _), do: false

  def get_element({:obj, ref} = obj, idx) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} when is_integer(idx) ->
        Runtime.TypedArray.get_element(obj, idx)

      list when is_list(list) and is_integer(idx) ->
        Enum.at(list, idx, :undefined)

      map when is_map(map) ->
        key = if is_integer(idx), do: Integer.to_string(idx), else: idx
        Map.get(map, key, Map.get(map, idx, :undefined))

      _ ->
        :undefined
    end
  end

  def get_element(obj, idx) when is_list(obj) and is_integer(idx),
    do: Enum.at(obj, idx, :undefined)

  def get_element(obj, idx) when is_map(obj), do: Map.get(obj, idx, :undefined)

  def get_element(s, idx) when is_binary(s) and is_integer(idx) and idx >= 0,
    do: String.at(s, idx) || :undefined

  def get_element(_, _), do: :undefined

  def put_element({:obj, ref} = obj, key, val) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} when is_integer(key) ->
        Runtime.TypedArray.set_element(obj, key, val)

      list when is_list(list) ->
        case key do
          i when is_integer(i) and i >= 0 and i < length(list) ->
            Heap.put_obj(ref, List.replace_at(list, i, val))

          _ ->
            :ok
        end

      map when is_map(map) ->
        str_key =
          case key do
            {:symbol, _, _} -> key
            {:symbol, _} -> key
            k when is_float(k) and k == trunc(k) and k >= 0 -> Integer.to_string(trunc(k))
            _ -> Kernel.to_string(key)
          end

        Heap.put_obj_key(ref, str_key, val)

      nil ->
        :ok
    end
  end

  def put_element(_, _, _), do: :ok

  def set_list_at(list, i, val) when is_integer(i) and i >= 0 and i < length(list),
    do: List.replace_at(list, i, val)

  def set_list_at(list, i, val) when is_integer(i) and i >= 0,
    do: list ++ List.duplicate(:undefined, max(0, i - length(list))) ++ [val]

end
