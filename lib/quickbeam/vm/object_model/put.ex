defmodule QuickBEAM.VM.ObjectModel.Put do
  @moduledoc false
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Bytecode, Heap, Names, Runtime}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.Get

  @compile {:inline, has_property: 2, get_element: 2, set_list_at: 3}

  defp shape_put(ref, shape_id, offsets, vals, proto, key, val) do
    case Map.fetch(offsets, key) do
      {:ok, offset} when offset < tuple_size(vals) ->
        Process.put(ref, {:shape, shape_id, offsets, put_elem(vals, offset, val), proto})

      {:ok, offset} ->
        Process.put(
          ref,
          {:shape, shape_id, offsets, Heap.Shapes.put_val(vals, offset, val), proto}
        )

      :error ->
        {new_shape_id, new_offsets, offset} = Heap.Shapes.transition(shape_id, key)

        new_vals =
          if offset == tuple_size(vals),
            do: :erlang.append_element(vals, val),
            else: Heap.Shapes.put_val(vals, offset, val)

        Process.put(ref, {:shape, new_shape_id, new_offsets, new_vals, proto})
    end
  end

  def put_field({:obj, ref}, key, val) do
    case Process.get(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        shape_put(ref, shape_id, offsets, vals, proto, key, val)

      _ ->
        put({:obj, ref}, key, val)
    end
  end

  def put({:obj, ref} = _obj, "length", val) do
    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        case Map.fetch(offsets, "length") do
          {:ok, offset} ->
            new_vals = Heap.Shapes.put_val(vals, offset, val)
            Heap.put_obj_raw(ref, {:shape, shape_id, offsets, new_vals, proto})

          :error ->
            {new_shape_id, new_offsets, offset} = Heap.Shapes.transition(shape_id, "length")
            new_vals = Heap.Shapes.put_val(vals, offset, val)
            Heap.put_obj_raw(ref, {:shape, new_shape_id, new_offsets, new_vals, proto})
        end

      data ->
        if is_list(data) or match?({:qb_arr, _}, data) do
          new_len = Runtime.to_int(val)
          list = if is_list(data), do: data, else: Heap.obj_to_list(ref)
          old_len = length(list)

          if new_len < old_len do
            non_configurable_idx =
              Enum.find(new_len..(old_len - 1), fn i ->
                match?(%{configurable: false}, Heap.get_prop_desc(ref, Integer.to_string(i)))
              end)

            if non_configurable_idx do
              Heap.put_obj(ref, Enum.take(list, non_configurable_idx + 1))
              throw({:js_throw, Heap.make_error("Cannot delete property", "TypeError")})
            end

            Heap.put_obj(ref, Enum.take(list, new_len))
          else
            padded = list ++ List.duplicate(:undefined, new_len - old_len)
            Heap.put_obj(ref, padded)
          end
        end
    end
  end

  def put({:obj, ref} = obj, key, val) do
    key = normalize_key(key)

    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        cond do
          Heap.frozen?(ref) ->
            :ok

          key == "__proto__" ->
            Heap.put_obj_raw(ref, {:shape, shape_id, offsets, vals, val})

          match?({:symbol, _}, key) or match?({:symbol, _, _}, key) ->
            map = Heap.Shapes.to_map(shape_id, vals, proto)
            Heap.put_obj(ref, Map.put(map, key, val))

          true ->
            shape_put(ref, shape_id, offsets, vals, proto, key, val)
        end

      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        set_trap = Get.get(handler, "set")

        if set_trap != :undefined do
          Runtime.call_callback(set_trap, [target, key, val])
        else
          put(target, key, val)
        end

      {:qb_arr, _} ->
        put_array_key(ref, key, val)

      list when is_list(list) ->
        put_array_key(ref, key, val)

      map when is_map(map) ->
        cond do
          Heap.frozen?(ref) ->
            :ok

          not Map.has_key?(map, key) ->
            Heap.put_obj_key(ref, map, key, val)

          match?({:accessor, _, setter} when setter != nil, Map.get(map, key)) ->
            {:accessor, _, setter} = Map.get(map, key)
            invoke_setter(setter, val, obj)

          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            :ok

          true ->
            Heap.put_obj_key(ref, map, key, val)
        end

      _ ->
        :ok
    end
  end

  def put(%Bytecode.Function{} = f, key, val), do: Heap.put_ctor_static(f, key, val)

  def put({:closure, _, %Bytecode.Function{}} = c, key, val),
    do: Heap.put_ctor_static(c, key, val)

  def put({:builtin, _, _} = b, key, val), do: Heap.put_ctor_static(b, key, val)

  def put(_, _, _), do: :ok

  def put(target, key, val, true), do: put(target, key, val)

  def put({:obj, ref}, key, val, false) do
    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        if not Heap.frozen?(ref) do
          shape_put(ref, shape_id, offsets, vals, proto, key, val)

          Heap.put_prop_desc(ref, key, %{writable: true, enumerable: false, configurable: true})
        end

        :ok

      map when is_map(map) ->
        if not Heap.frozen?(ref) do
          Heap.put_obj(ref, Map.put(map, key, val))
          Heap.put_prop_desc(ref, key, %{writable: true, enumerable: false, configurable: true})
        end

        :ok

      _ ->
        :ok
    end
  end

  def put(%Bytecode.Function{} = f, key, val, _enumerable), do: Heap.put_ctor_static(f, key, val)

  def put({:closure, _, %Bytecode.Function{}} = c, key, val, _enumerable),
    do: Heap.put_ctor_static(c, key, val)

  def put({:builtin, _, _} = b, key, val, _enumerable), do: Heap.put_ctor_static(b, key, val)

  def put(_, _, _, _), do: :ok

  defp normalize_key(k) when is_float(k) and k == trunc(k) and k >= 0,
    do: k |> trunc() |> Integer.to_string()

  defp normalize_key(k) when is_float(k), do: Values.stringify(k)
  defp normalize_key({:tagged_int, n}), do: Integer.to_string(n)
  defp normalize_key(k) when is_integer(k) and k >= 0, do: Integer.to_string(k)
  defp normalize_key(k), do: k

  defp put_array_key(ref, key, val) do
    case key do
      k when is_binary(k) ->
        case Integer.parse(k) do
          {idx, ""} when idx >= 0 -> put_element({:obj, ref}, idx, val)
          _ -> :ok
        end

      k when is_integer(k) and k >= 0 ->
        put_element({:obj, ref}, k, val)

      _ ->
        :ok
    end
  end

  def put_getter({:obj, ref}, key, fun) do
    update_getter(ref, key, fun)
  end

  def put_getter(target, key, fun), do: Heap.put_ctor_static(target, key, {:accessor, fun, nil})

  def put_getter(target, key, fun, true), do: put_getter(target, key, fun)

  def put_getter({:obj, ref}, key, fun, false) do
    update_getter(ref, key, fun)
    Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true})
  end

  def put_getter(target, key, fun, _enumerable),
    do: Heap.put_ctor_static(target, key, {:accessor, fun, nil})

  def put_setter({:obj, ref}, key, fun) do
    update_setter(ref, key, fun)
  end

  def put_setter(target, key, fun), do: Heap.put_ctor_static(target, key, {:accessor, nil, fun})

  def put_setter(target, key, fun, true), do: put_setter(target, key, fun)

  def put_setter({:obj, ref}, key, fun, false) do
    update_setter(ref, key, fun)
    Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true})
  end

  def put_setter(target, key, fun, _enumerable),
    do: Heap.put_ctor_static(target, key, {:accessor, nil, fun})

  defp update_getter(ref, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc =
        case Map.get(map, key) do
          {:accessor, _get, set} -> {:accessor, fun, set}
          _ -> {:accessor, fun, nil}
        end

      Map.put(map, key, desc)
    end)
  end

  defp update_setter(ref, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc =
        case Map.get(map, key) do
          {:accessor, get, _set} -> {:accessor, get, fun}
          _ -> {:accessor, nil, fun}
        end

      Map.put(map, key, desc)
    end)
  end

  defp invoke_setter(fun, val, this_obj) do
    Invocation.invoke_with_receiver(fun, [val], this_obj)
  end

  defp proto_has_setter?(idx) do
    case find_array_proto_accessor(Integer.to_string(idx)) do
      {:accessor, _, setter} when setter != nil -> true
      _ -> false
    end
  end

  defp invoke_proto_setter(obj, idx, val) do
    case find_array_proto_accessor(Integer.to_string(idx)) do
      {:accessor, _, setter} when setter != nil -> invoke_setter(setter, val, obj)
      _ -> :ok
    end
  end

  defp find_array_proto_accessor(str_key) do
    with %{globals: globals} <- Heap.get_ctx(),
         array_ctor when array_ctor != nil <- Map.get(globals, "Array"),
         {:obj, proto_ref} <- Map.get(Heap.get_ctor_statics(array_ctor), "prototype"),
         map when is_map(map) <- Heap.get_obj(proto_ref, nil) do
      Map.get(map, str_key)
    else
      _ -> nil
    end
  end



  def has_property({:obj, ref}, key) do
    map = Heap.get_obj(ref, %{})

    case map do
      %{
        proxy_target() => target,
        proxy_handler() => handler
      } ->
        has_trap = Get.get(handler, "has")

        if has_trap != :undefined do
          Runtime.call_callback(has_trap, [target, key])
        else
          has_property(target, key)
        end

      _ when is_map(map) ->
        Map.has_key?(map, key) or Get.get({:obj, ref}, key) != :undefined

      _ ->
        Get.get({:obj, ref}, key) != :undefined
    end
  end

  def has_property({:builtin, _, _} = b, key) do
    Get.get(b, key) != :undefined
  end

  def has_property(obj, key) when is_map(obj), do: Map.has_key?(obj, key)

  def has_property({:qb_arr, arr}, key) when is_integer(key),
    do: key >= 0 and key < :array.size(arr)

  def has_property(obj, key) when is_list(obj) and is_integer(key),
    do: key >= 0 and key < length(obj)

  def has_property(_, _), do: false

  def get_element({:obj, ref} = obj, idx) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} when is_integer(idx) ->
        Runtime.TypedArray.get_element(obj, idx)

      {:qb_arr, arr} when is_integer(idx) ->
        if idx >= 0 and idx < :array.size(arr),
          do: :array.get(idx, arr),
          else: :undefined

      list when is_list(list) and is_integer(idx) ->
        Enum.at(list, idx, :undefined)

      map when is_map(map) ->
        key = if is_integer(idx), do: Integer.to_string(idx), else: idx

        case Map.fetch(map, key) do
          {:ok, val} ->
            val

          :error ->
            case Map.fetch(map, idx) do
              {:ok, val} ->
                val

              :error when is_binary(key) or is_binary(idx) ->
                Get.get(obj, if(is_binary(key), do: key, else: idx))

              :error ->
                :undefined
            end
        end

      {:shape, _, _, _, _} when is_binary(idx) or is_integer(idx) ->
        Get.get(obj, if(is_integer(idx), do: Integer.to_string(idx), else: idx))

      _ ->
        :undefined
    end
  end

  def get_element({:qb_arr, arr}, idx) when is_integer(idx) do
    if idx >= 0 and idx < :array.size(arr),
      do: :array.get(idx, arr),
      else: :undefined
  end

  def get_element(obj, idx) when is_list(obj) and is_integer(idx),
    do: Enum.at(obj, idx, :undefined)

  def get_element(obj, idx) when is_map(obj), do: Map.get(obj, idx, :undefined)

  def get_element(s, idx) when is_binary(s) and is_integer(idx) and idx >= 0,
    do: String.at(s, idx) || :undefined

  def get_element(s, key) when is_binary(s) and is_binary(key),
    do: Get.get(s, key)

  def get_element(nil, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot read properties of null (reading '#{Values.stringify(key)}')",
         "TypeError"
       )}
    )
  end

  def get_element(:undefined, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot read properties of undefined (reading '#{Values.stringify(key)}')",
         "TypeError"
       )}
    )
  end

  def get_element(obj, key) when is_binary(key) do
    Get.get(obj, key)
  end

  def get_element({:builtin, _, _} = b, {:symbol, _} = sym_key) do
    case Map.get(Heap.get_ctor_statics(b), sym_key) do
      {:accessor, getter, _} when getter != nil ->
        Runtime.call_callback(getter, [])

      nil ->
        :undefined

      val ->
        val
    end
  end

  def get_element({:obj, ref}, {:symbol, _} = sym_key) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case Map.get(map, sym_key) do
          {:accessor, getter, _} when getter != nil ->
            Runtime.call_callback(getter, [])

          nil ->
            :undefined

          val ->
            val
        end

      _ ->
        :undefined
    end
  end

  def get_element(_, _), do: :undefined

  def put_element({:obj, ref} = obj, key, val) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} when is_integer(key) ->
        Runtime.TypedArray.set_element(obj, key, val)

      {:qb_arr, arr} ->
        case key do
          i when is_integer(i) and i >= 0 ->
            if i >= :array.size(arr) and proto_has_setter?(i) do
              invoke_proto_setter(obj, i, val)
            else
              Heap.array_set(ref, i, val)
            end

          _ -> :ok
        end

      list when is_list(list) ->
        case key do
          i when is_integer(i) and i >= 0 and i < length(list) ->
            Heap.put_obj(ref, List.replace_at(list, i, val))

          i when is_integer(i) and i >= 0 ->
            if proto_has_setter?(i) do
              invoke_proto_setter(obj, i, val)
            else
              padded = list ++ List.duplicate(:undefined, i - length(list)) ++ [val]
              Heap.put_obj(ref, padded)
            end

          _ ->
            :ok
        end

      map when is_map(map) ->
        str_key =
          case key do
            {:symbol, _, _} -> key
            {:symbol, _} -> key
            k when is_float(k) and k == trunc(k) and k >= 0 -> Integer.to_string(trunc(k))
            _ -> Values.stringify(key)
          end

        Heap.put_obj_key(ref, map, str_key, val)

      nil ->
        :ok
    end
  end

  def put_element(_, _, _), do: :ok

  def define_array_el(obj, idx, val) do
    obj2 =
      case obj do
        list when is_list(list) ->
          i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
          set_list_at(list, i, val)

        {:obj, ref} ->
          stored = Heap.get_obj(ref, [])

          cond do
            match?({:qb_arr, _}, stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.array_set(ref, i, val)

            is_list(stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.put_obj(ref, set_list_at(stored, i, val))

            is_map(stored) ->
              Heap.put_obj_key(ref, stored, Names.normalize_property_key(idx), val)

            true ->
              :ok
          end

          {:obj, ref}

        %Bytecode.Function{} = ctor ->
          Heap.put_ctor_static(ctor, Names.normalize_property_key(idx), val)
          ctor

        {:closure, _, %Bytecode.Function{}} = ctor ->
          Heap.put_ctor_static(ctor, Names.normalize_property_key(idx), val)
          ctor

        {:builtin, _, _} = ctor ->
          Heap.put_ctor_static(ctor, Names.normalize_property_key(idx), val)
          ctor

        _ ->
          obj
      end

    {idx, obj2}
  end

  def set_list_at(list, i, val) when is_integer(i) and i >= 0 and i < length(list),
    do: List.replace_at(list, i, val)

  def set_list_at(list, i, val) when is_integer(i) and i >= 0,
    do: list ++ List.duplicate(:undefined, max(0, i - length(list))) ++ [val]
end
