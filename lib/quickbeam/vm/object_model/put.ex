defmodule QuickBEAM.VM.ObjectModel.Put do
  @moduledoc "Property write operations: set, define, and delete for JS objects, arrays, proxies, getters, and setters."
  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1]

  alias QuickBEAM.VM.Execution.{RegexpState, SetterState}
  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Get,
    HasProperty,
    OwnProperty,
    PropertyDescriptor,
    PropertyKey,
    Semantics,
    WrappedPrimitive
  }

  @compile {:inline, has_property: 2, get_element: 2, set_list_at: 3}

  @max_array_length 4_294_967_295

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

  @doc "Writes a field using the fast shape path when possible."
  def put_field({:obj, ref}, key, val) do
    key = normalize_key(key)

    case Process.get(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        shape_put(ref, shape_id, offsets, vals, proto, key, val)

      _ ->
        put({:obj, ref}, key, val)
    end
  end

  defp resize_array(ref, {:qb_arr, arr}, new_len) do
    old_len = :array.size(arr)
    virtual_len = virtual_array_length(ref)

    cond do
      virtual_len != nil and new_len >= old_len ->
        put_virtual_array_length(ref, old_len, new_len)

      new_len > old_len and huge_length_growth?(old_len, new_len) ->
        Heap.put_array_prop(ref, "length", new_len)

      new_len < old_len ->
        non_configurable_idx = non_configurable_array_index(ref, new_len, old_len)

        if non_configurable_idx do
          kept_len = non_configurable_idx + 1
          delete_array_index_metadata(ref, kept_len, old_len)
          Heap.put_obj_raw(ref, {:qb_arr, resize_sparse_array(arr, kept_len, old_len)})
          reject_failed_write!()
        else
          delete_array_index_metadata(ref, new_len, old_len)
          delete_sparse_array_props_from(ref, new_len)
          Heap.put_obj_raw(ref, {:qb_arr, resize_sparse_array(arr, new_len, old_len)})
        end

      true ->
        Heap.put_obj_raw(ref, {:qb_arr, resize_sparse_array(arr, new_len, old_len)})
    end
  end

  defp resize_array(ref, list, new_len) do
    old_len = length(list)
    virtual_len = virtual_array_length(ref)

    cond do
      virtual_len != nil and new_len >= old_len ->
        put_virtual_array_length(ref, old_len, new_len)

      new_len > old_len and huge_length_growth?(old_len, new_len) ->
        Heap.put_array_prop(ref, "length", new_len)

      new_len < old_len ->
        non_configurable_idx = non_configurable_array_index(ref, new_len, old_len)

        if non_configurable_idx do
          delete_array_index_metadata(ref, non_configurable_idx + 1, old_len)
          Heap.put_obj(ref, Enum.take(list, non_configurable_idx + 1))
          reject_failed_write!()
        else
          delete_array_index_metadata(ref, new_len, old_len)
          delete_sparse_array_props_from(ref, new_len)
          Heap.put_obj(ref, Enum.take(list, new_len))
        end

      true ->
        padded = list ++ List.duplicate(:undefined, new_len - old_len)
        Heap.put_obj(ref, padded)
    end
  end

  defp array_length_value!(value) do
    new_len = Runtime.to_number(value, "number")
    number_len = Runtime.to_number(value, "number")

    if not is_number(new_len) or not is_number(number_len) or new_len < 0 or
         new_len != trunc(new_len) or new_len > @max_array_length or number_len != new_len do
      JSThrow.range_error!("Invalid array length")
    else
      trunc(new_len)
    end
  end

  defp virtual_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ -> nil
    end
  end

  defp put_virtual_array_length(ref, old_len, new_len) do
    if new_len == old_len do
      Heap.delete_array_prop(ref, "length")
    else
      Heap.put_array_prop(ref, "length", new_len)
    end
  end

  defp huge_length_growth?(old_len, new_len), do: new_len - old_len > 1_000_000

  defp resize_sparse_array(arr, new_len, old_len) when new_len < old_len do
    cleared =
      new_len..(old_len - 1)
      |> Enum.reduce(arr, fn index, acc -> :array.reset(index, acc) end)

    :array.resize(new_len, cleared)
  end

  defp resize_sparse_array(arr, new_len, _old_len), do: :array.resize(new_len, arr)

  defp non_configurable_array_index(ref, new_len, old_len) do
    Enum.find(new_len..(old_len - 1), fn i ->
      match?(%{configurable: false}, Heap.get_prop_desc(ref, Integer.to_string(i)))
    end)
  end

  defp delete_array_index_metadata(_ref, from, to) when from >= to, do: :ok

  defp delete_array_index_metadata(ref, from, to) do
    Enum.each(from..(to - 1), fn i ->
      key = Integer.to_string(i)
      Heap.delete_prop_desc(ref, key)
      Heap.delete_array_prop(ref, key)
    end)
  end

  defp delete_sparse_array_props_from(ref, from) do
    ref
    |> Heap.get_array_props()
    |> Map.keys()
    |> Enum.each(fn key ->
      case PropertyKey.array_index(key) do
        {:ok, idx} when idx >= from ->
          Heap.delete_prop_desc(ref, key)
          Heap.delete_array_prop(ref, key)

        _ ->
          :ok
      end
    end)
  end

  @doc "Writes a JavaScript property while respecting arrays, proxies, descriptors, accessors, and constructor statics."
  def put({:obj, ref} = obj, "length", val) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, _vals, _proto}
      when is_map_key(offsets, "constructor") and is_map_key(offsets, "push") and
             is_map_key(offsets, "pop") ->
        put_array_prototype_length(ref, val)

      map
      when is_map(map) and is_map_key(map, "constructor") and is_map_key(map, "push") and
             is_map_key(map, "pop") ->
        put_array_prototype_length(ref, val)

      map when is_map(map) ->
        case Map.get(map, "length") do
          {:accessor, _getter, setter} when setter != nil ->
            invoke_setter(setter, val, obj)

          {:accessor, _getter, nil} ->
            reject_failed_write!()

          _ ->
            put_length_property(obj, ref, val)
        end

      _ ->
        put_length_property(obj, ref, val)
    end
  end

  def put({:obj, ref} = obj, key, val) do
    key = normalize_key(key)
    sync_global_this?(obj, key, val)

    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        cond do
          Heap.frozen?(ref) ->
            :ok

          key == "__proto__" ->
            Heap.put_obj_raw(ref, {:shape, shape_id, offsets, vals, val})

          wrapped_shape_string_virtual_readonly?(offsets, vals, key) ->
            :ok

          not Map.has_key?(offsets, key) and proto_has_setter_property?(proto, key) ->
            set(proto, key, val, obj)

          not Map.has_key?(offsets, key) and proto_has_getter_only_property?(proto, key) ->
            :ok

          not Heap.extensible?(ref) and not Map.has_key?(offsets, key) ->
            :ok

          is_symbol(key) ->
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
          validate_proxy_set_invariant(
            target,
            key,
            val,
            Runtime.call_callback(set_trap, [target, key, val])
          )
        else
          put(target, key, val)
        end

      {:qb_arr, _} ->
        put_array_key(ref, key, val)

      list when is_list(list) ->
        put_array_key(ref, key, val)

      map when is_map(map) ->
        cond do
          match?({:accessor, _, setter} when setter != nil, Map.get(map, key)) ->
            {:accessor, _, setter} = Map.get(map, key)
            invoke_setter(setter, val, obj)

          Heap.frozen?(ref) ->
            :ok

          wrapped_string_virtual_readonly?(map, key) ->
            :ok

          not Map.has_key?(map, key) and proto_has_setter_property?(Map.get(map, proto()), key) ->
            set(Map.get(map, proto()), key, val, obj)

          not Map.has_key?(map, key) and
              proto_has_getter_only_property?(Map.get(map, proto()), key) ->
            :ok

          not Map.has_key?(map, key) and not Heap.extensible?(ref) ->
            :ok

          not Map.has_key?(map, key) ->
            Heap.put_obj_key(ref, map, key, val)

          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            :ok

          true ->
            Heap.put_obj_key(ref, map, key, val)
        end

      _ ->
        :ok
    end
  end

  def put(%QuickBEAM.VM.Function{} = f, key, val), do: put_callable_property(f, key, val)

  def put({:closure, _, %QuickBEAM.VM.Function{}} = c, key, val),
    do: put_callable_property(c, key, val)

  def put({:builtin, _name, map} = b, key, val) when is_map(map) do
    case callable_prop_desc(b, key) do
      %{writable: false} -> reject_failed_write!()
      _ -> Heap.put_ctor_static(b, key, val)
    end
  end

  def put({:builtin, _, _} = b, key, val), do: put_callable_property(b, key, val)
  def put({:bound, _, _, _, _} = b, key, val), do: put_callable_property(b, key, val)

  def put({:regexp, _, _, ref}, key, val) do
    key = normalize_key(key)

    RegexpState.put(ref, key, val)
  end

  def put(_, _, _), do: :ok

  defp put_array_prototype_length(ref, val) do
    new_len = array_length_value!(val)

    case Heap.get_prop_desc(ref, "length") do
      %{writable: false} ->
        reject_failed_write!()

      _ ->
        Heap.put_array_prop(ref, "length", new_len)

        if Heap.get_prop_desc(ref, "length") == nil do
          Heap.put_prop_desc(ref, "length", %{
            writable: true,
            enumerable: false,
            configurable: false
          })
        end
    end
  end

  defp put_length_property(obj, ref, val) do
    case Heap.get_obj_raw(ref) do
      {:qb_arr, _} = array -> put_array_length_property(ref, array, val)
      data when is_list(data) -> put_array_length_property(ref, data, val)
      _ -> put_ordinary_length_property(obj, ref, val)
    end
  end

  defp put_array_length_property(ref, array, val) do
    new_len = array_length_value!(val)

    case Heap.get_prop_desc(ref, "length") do
      %{writable: false} -> reject_failed_write!()
      _ -> resize_array(ref, array, new_len)
    end
  end

  defp put_ordinary_length_property(obj, ref, val) do
    case Heap.get_prop_desc(ref, "length") do
      %{writable: false} -> :ok
      _ -> put_length(obj, val)
    end
  end

  defp put_length({:obj, ref}, val) do
    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        if wrapped_shape_string_virtual_readonly?(offsets, vals, "length") do
          :ok
        else
          case Map.fetch(offsets, "length") do
            {:ok, offset} ->
              new_vals = Heap.Shapes.put_val(vals, offset, val)
              Heap.put_obj_raw(ref, {:shape, shape_id, offsets, new_vals, proto})

            :error ->
              {new_shape_id, new_offsets, offset} = Heap.Shapes.transition(shape_id, "length")
              new_vals = Heap.Shapes.put_val(vals, offset, val)
              Heap.put_obj_raw(ref, {:shape, new_shape_id, new_offsets, new_vals, proto})
          end
        end

      {:qb_arr, _} = array ->
        resize_array(ref, array, array_length_value!(val))

      data when is_list(data) ->
        resize_array(ref, data, array_length_value!(val))

      map when is_map(map) ->
        case WrappedPrimitive.value(map, :string) do
          {:ok, string} when is_binary(string) -> :ok
          _ -> Heap.put_obj_key(ref, map, "length", val)
        end

      _ ->
        :ok
    end
  end

  defp wrapped_shape_string_virtual_readonly?(offsets, vals, "length") do
    case Map.fetch(offsets, WrappedPrimitive.slot(:string)) do
      {:ok, offset} when offset < tuple_size(vals) -> is_binary(elem(vals, offset))
      _ -> false
    end
  end

  defp wrapped_shape_string_virtual_readonly?(offsets, vals, key) do
    with {:ok, offset} when offset < tuple_size(vals) <-
           Map.fetch(offsets, WrappedPrimitive.slot(:string)),
         string when is_binary(string) <- elem(vals, offset),
         index when is_integer(index) <- Semantics.parse_array_index_key(key) do
      index >= 0 and index < Get.string_length(string)
    else
      _ -> false
    end
  end

  defp wrapped_string_virtual_readonly?(map, "length") do
    match?({:ok, string} when is_binary(string), WrappedPrimitive.value(map, :string))
  end

  defp wrapped_string_virtual_readonly?(map, key) when is_map(map) do
    with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(map, :string),
         index when is_integer(index) <- Semantics.parse_array_index_key(key) do
      index >= 0 and index < Get.string_length(string)
    else
      _ -> false
    end
  end

  defp wrapped_string_virtual_readonly?(_map, _key), do: false

  @doc "Writes a property using an explicit receiver, for Reflect.set semantics."
  def set({:obj, ref}, key, val, receiver) do
    key = normalize_key(key)
    raw = Heap.get_obj_raw(ref)

    case {key, raw} do
      {"length", {:qb_arr, _} = array} when receiver == {:obj, ref} ->
        set_array_length_property(ref, array, val)

      {"length", data} when is_list(data) and receiver == {:obj, ref} ->
        set_array_length_property(ref, data, val)

      _ ->
        set_property(ref, raw, key, val, receiver)
    end
  end

  def set(target, key, val, _receiver), do: put(target, key, val)

  defp set_property(ref, raw, key, val, receiver) do
    case raw do
      %{proxy_target() => proxy_target, proxy_handler() => handler} ->
        set_trap = Get.get(handler, "set")

        if set_trap != :undefined do
          validate_proxy_set_invariant(
            proxy_target,
            key,
            val,
            Runtime.call_callback(set_trap, [proxy_target, key, val, receiver])
          )
        else
          set(proxy_target, key, val, receiver)
        end

      {:shape, _shape_id, offsets, vals, proto_obj} ->
        case Map.fetch(offsets, key) do
          {:ok, offset} ->
            case elem(vals, offset) do
              {:accessor, _, setter} when setter != nil ->
                invoke_setter(setter, val, receiver)
                true

              _ ->
                if match?(%{writable: false}, Heap.get_prop_desc(ref, key)) do
                  false
                else
                  write_receiver(receiver, key, val)
                end
            end

          :error ->
            if proto_has_property?(proto_obj, key) do
              set(proto_obj, key, val, receiver)
            else
              write_receiver(receiver, key, val)
            end
        end

      map when is_map(map) ->
        case Map.get(map, key) do
          nil ->
            if proto_has_property?(Map.get(map, proto()), key) do
              set(Map.get(map, proto()), key, val, receiver)
            else
              write_receiver(receiver, key, val)
            end

          {:accessor, _, setter} when setter != nil ->
            invoke_setter(setter, val, receiver)
            true

          _ ->
            if match?(%{writable: false}, Heap.get_prop_desc(ref, key)) do
              false
            else
              write_receiver(receiver, key, val)
            end
        end

      _ ->
        write_receiver(receiver, key, val)
    end
  end

  defp set_array_length_property(ref, array, val) do
    new_len = array_length_value!(val)

    case Heap.get_prop_desc(ref, "length") do
      %{writable: false} ->
        false

      _ ->
        resize_array(ref, array, new_len)
        true
    end
  end

  defp write_receiver({:obj, ref} = receiver, key, val) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => _target, proxy_handler() => _handler} ->
        desc = receiver_write_descriptor(receiver, key, val)
        Define.property(receiver, key, Heap.wrap(desc), desc)
        true

      {:shape, _shape_id, offsets, vals, _proto} ->
        case Map.fetch(offsets, key) do
          {:ok, offset} ->
            case elem(vals, offset) do
              {:accessor, _, _} ->
                false

              _ ->
                if match?(%{writable: false}, Heap.get_prop_desc(ref, key)) do
                  false
                else
                  put(receiver, key, val)
                  true
                end
            end

          :error ->
            if Heap.extensible?(ref) do
              put(receiver, key, val)
              true
            else
              false
            end
        end

      map when is_map(map) ->
        case Map.get(map, key) do
          nil ->
            if Heap.extensible?(ref) do
              put(receiver, key, val)
              true
            else
              false
            end

          {:accessor, _, _} ->
            false

          _ ->
            if match?(%{writable: false}, Heap.get_prop_desc(ref, key)) do
              false
            else
              put(receiver, key, val)
              true
            end
        end

      _ ->
        put(receiver, key, val)
        true
    end
  end

  defp write_receiver(receiver, key, val) do
    if receiver_object?(receiver) do
      put(receiver, key, val)
      true
    else
      false
    end
  end

  defp receiver_write_descriptor(receiver, key, val) do
    case OwnProperty.descriptor(receiver, key) do
      :undefined ->
        %{"value" => val, "writable" => true, "enumerable" => true, "configurable" => true}

      _descriptor ->
        %{"value" => val}
    end
  end

  defp receiver_object?({:obj, _}), do: true
  defp receiver_object?(%QuickBEAM.VM.Function{}), do: true
  defp receiver_object?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp receiver_object?({:bound, _, _, _, _}), do: true
  defp receiver_object?({:builtin, _, _}), do: true
  defp receiver_object?(_), do: false

  def put(target, key, val, true), do: put(target, key, val)

  def put({:obj, ref}, key, val, false) do
    case Heap.get_obj_raw(ref) do
      {:shape, shape_id, offsets, vals, proto} ->
        if not Heap.frozen?(ref) do
          shape_put(ref, shape_id, offsets, vals, proto, key, val)
          Heap.put_prop_desc(ref, key, PropertyDescriptor.method())
        end

        :ok

      map when is_map(map) ->
        if not Heap.frozen?(ref) do
          Heap.put_obj(ref, Map.put(map, key, val))
          Heap.put_prop_desc(ref, key, PropertyDescriptor.method())
        end

        :ok

      _ ->
        :ok
    end
  end

  def put(%QuickBEAM.VM.Function{} = f, key, val, _enumerable),
    do: put_callable_property(f, key, val)

  def put({:closure, _, %QuickBEAM.VM.Function{}} = c, key, val, _enumerable),
    do: put_callable_property(c, key, val)

  def put({:builtin, _, _} = b, key, val, _enumerable), do: put_callable_property(b, key, val)
  def put({:bound, _, _, _, _} = b, key, val, _enumerable), do: put_callable_property(b, key, val)

  def put(_, _, _, _), do: :ok

  defp put_callable_property(callable, key, val) do
    statics = Heap.get_ctor_statics(callable)
    own? = Map.has_key?(statics, key)

    cond do
      key in ["length", "name"] and (not own? or Map.get(statics, key) == :deleted) ->
        reject_failed_write!()

      key in ["caller", "arguments"] and restricted_function_property?(callable) ->
        JSThrow.type_error!("'caller' and 'arguments' are restricted function properties")

      match?({:accessor, _, nil}, Map.get(statics, key)) ->
        reject_failed_write!()

      match?(%{writable: false}, callable_prop_desc(callable, key)) or
        inherited_object_property_readonly?(callable, key) or
          inherited_object_getter_only?(callable, key) ->
        :ok

      not own? and function_proto_has_setter?(key) ->
        invoke_function_proto_setter(callable, key, val)

      not own? and function_proto_has_getter_only?(key) ->
        :ok

      true ->
        Heap.put_ctor_static(callable, key, val)
    end
  end

  defp normalize_key(k), do: PropertyKey.normalize(k)

  defp callable_prop_desc(callable, key),
    do: Heap.get_prop_desc(callable, key) || Heap.get_ctor_prop_desc(callable, key)

  defp inherited_object_property_readonly?(callable, key) do
    own? = Map.has_key?(Heap.get_ctor_statics(callable), key)

    object_proto_readonly? =
      case Heap.get_object_prototype() do
        {:obj, _} = proto ->
          case QuickBEAM.VM.ObjectModel.OwnProperty.descriptor(proto, key) do
            {:obj, desc_ref} -> Get.get({:obj, desc_ref}, "writable") == false
            _ -> false
          end

        _ ->
          false
      end

    not own? and object_proto_readonly?
  end

  defp inherited_object_getter_only?(callable, key) do
    not Map.has_key?(Heap.get_ctor_statics(callable), key) and
      proto_has_getter_only_property?(Heap.get_object_prototype(), key)
  end

  defp put_array_named_property(obj, ref, key, val) do
    case Heap.get_array_prop(ref, key) do
      {:accessor, _getter, setter} when setter != nil ->
        invoke_setter(setter, val, obj)

      {:accessor, _getter, nil} ->
        :ok

      _ ->
        cond do
          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            :ok

          not array_named_property_present?(ref, key) and proto_has_named_setter?(key) ->
            invoke_named_proto_setter(obj, key, val)

          true ->
            Heap.put_array_prop(ref, key, val)
            mark_undefined_array_write(ref, key, val)
        end
    end
  end

  defp put_array_key(ref, key, val) do
    obj = {:obj, ref}

    case key do
      k when is_binary(k) ->
        case PropertyKey.array_index(k) do
          {:ok, idx} -> put_element({:obj, ref}, idx, val)
          :error -> put_array_named_property(obj, ref, k, val)
        end

      k when is_symbol(k) ->
        put_array_named_property(obj, ref, k, val)

      _ ->
        :ok
    end
  end

  @doc "Defines or replaces a JavaScript getter property."
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

  @doc "Defines or replaces a JavaScript setter property."
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

      put_property_preserving_order(map, key, desc)
    end)
  end

  defp update_setter(ref, key, fun) do
    Heap.update_obj(ref, %{}, fn map ->
      desc =
        case Map.get(map, key) do
          {:accessor, get, _set} -> {:accessor, get, fun}
          _ -> {:accessor, nil, fun}
        end

      put_property_preserving_order(map, key, desc)
    end)
  end

  defp put_property_preserving_order(map, key, value),
    do: QuickBEAM.VM.Heap.Store.put_property_preserving_order(map, key, value)

  defp invoke_setter(fun, val, this_obj) do
    try do
      result = Invocation.invoke_with_receiver(fun, [val], this_obj)
      SetterState.mark_invoked()
      result
    rescue
      error ->
        SetterState.clear()
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        SetterState.clear()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp proto_has_property?(nil, _key), do: false
  defp proto_has_property?(:undefined, _key), do: false

  defp proto_has_property?({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        Map.has_key?(map, key) or proto_has_property?(Map.get(map, proto()), key)

      _ ->
        has_property(obj, key)
    end
  end

  defp proto_has_property?(proto_obj, key), do: has_property(proto_obj, key)

  defp proto_has_setter_property?(nil, _key), do: false
  defp proto_has_setter_property?(:undefined, _key), do: false

  defp proto_has_setter_property?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, vals, parent_proto} ->
        case Map.fetch(offsets, key) do
          {:ok, off} ->
            match?({:accessor, _, setter} when setter != nil, elem(vals, off))

          :error ->
            proto_has_setter_property?(parent_proto, key)
        end

      map when is_map(map) ->
        case Map.get(map, key) do
          {:accessor, _, setter} when setter != nil -> true
          _ -> proto_has_setter_property?(Map.get(map, proto()), key)
        end

      _ ->
        false
    end
  end

  defp proto_has_setter_property?(_proto_obj, _key), do: false

  defp proto_has_getter_only_property?(nil, _key), do: false
  defp proto_has_getter_only_property?(:undefined, _key), do: false

  defp proto_has_getter_only_property?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, vals, parent_proto} ->
        case Map.fetch(offsets, key) do
          {:ok, off} -> match?({:accessor, getter, nil} when getter != nil, elem(vals, off))
          :error -> proto_has_getter_only_property?(parent_proto, key)
        end

      map when is_map(map) ->
        case Map.get(map, key) do
          {:accessor, getter, nil} when getter != nil -> true
          _ -> proto_has_getter_only_property?(Map.get(map, proto()), key)
        end

      _ ->
        false
    end
  end

  defp proto_has_getter_only_property?(_proto_obj, _key), do: false

  defp function_proto_has_setter?(key) do
    case function_proto_property(key) do
      {:accessor, _, setter} when setter != nil -> true
      _ -> false
    end
  end

  defp function_proto_has_getter_only?(key) do
    case function_proto_property(key) do
      {:accessor, getter, nil} when getter != nil -> true
      _ -> false
    end
  end

  defp invoke_function_proto_setter(callable, key, val) do
    case function_proto_property(key) do
      {:accessor, _, setter} when setter != nil -> invoke_setter(setter, val, callable)
      _ -> :ok
    end
  end

  defp function_proto_property(key) do
    case Heap.get_func_proto() do
      {:obj, ref} ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) -> Map.get(map, key)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp array_named_property_present?(ref, key) do
    case Heap.get_array_prop(ref, key) do
      :undefined -> false
      _ -> true
    end
  end

  defp proto_has_named_setter?(key) when is_binary(key) do
    case find_array_proto_accessor(key) do
      {:accessor, _, setter} when setter != nil -> true
      _ -> false
    end
  end

  defp proto_has_named_setter?(_), do: false

  defp invoke_named_proto_setter(obj, key, val) do
    case find_array_proto_accessor(key) do
      {:accessor, _, setter} when setter != nil -> invoke_setter(setter, val, obj)
      _ -> :ok
    end
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
         {:obj, _} = proto <- Map.get(Heap.get_ctor_statics(array_ctor), "prototype") do
      find_proto_accessor(proto, str_key)
    else
      _ -> nil
    end
  end

  defp find_proto_accessor(nil, _key), do: nil
  defp find_proto_accessor(:undefined, _key), do: nil

  defp find_proto_accessor({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:shape, _shape_id, offsets, vals, parent_proto} ->
        case Map.fetch(offsets, key) do
          {:ok, off} -> elem(vals, off)
          :error -> find_proto_accessor(parent_proto, key)
        end

      map when is_map(map) ->
        case Map.get(map, key) do
          nil -> find_proto_accessor(next_proto(ref, map), key)
          value -> value
        end

      _ ->
        nil
    end
  end

  defp next_proto(ref, map) do
    Map.get(map, proto()) || object_proto_fallback(ref)
  end

  defp object_proto_fallback(ref) do
    case Heap.get_object_prototype() do
      {:obj, ^ref} -> nil
      proto -> proto
    end
  end

  @doc "Returns whether a value has a property in its own or prototype chain."
  def has_property(value, key), do: HasProperty.has_property?(value, key)

  defp array_index_beyond_length?(obj, ref, index) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) ->
        index >= len

      _ ->
        case Get.length_of(obj) do
          len when is_integer(len) -> index >= len
          _ -> false
        end
    end
  end

  defp array_index_value(obj, ref, key, fallback) do
    case Heap.get_array_prop(ref, key) do
      {:accessor, getter, _} when getter != nil ->
        Get.call_getter(getter, obj)

      {:accessor, nil, _} ->
        :undefined

      :undefined ->
        value = fallback.()

        if value == :undefined and Heap.get_prop_desc(ref, key) == nil do
          Get.get(obj, key)
        else
          value
        end

      value ->
        value
    end
  end

  @doc "Reads an indexed JavaScript element."
  def get_element({:obj, ref} = obj, idx) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} when is_integer(idx) ->
        Runtime.TypedArray.get_element(obj, idx)

      {:qb_arr, arr} ->
        case PropertyKey.array_index(idx) do
          {:ok, index} ->
            key = Integer.to_string(index)

            if array_index_beyond_length?(obj, ref, index) do
              Get.get(obj, key)
            else
              array_index_value(obj, ref, key, fn ->
                if index < :array.size(arr), do: :array.get(index, arr), else: :undefined
              end)
            end

          :error ->
            Get.get(obj, PropertyKey.normalize(idx))
        end

      list when is_list(list) ->
        case PropertyKey.array_index(idx) do
          {:ok, index} ->
            key = Integer.to_string(index)

            if array_index_beyond_length?(obj, ref, index) do
              Get.get(obj, key)
            else
              array_index_value(obj, ref, key, fn ->
                Enum.at(list, index, :undefined)
              end)
            end

          :error ->
            Get.get(obj, PropertyKey.normalize(idx))
        end

      map when is_map(map) ->
        key = PropertyKey.normalize(idx)

        case Map.fetch(map, key) do
          {:ok, {:accessor, getter, _}} when getter != nil ->
            Get.call_getter(getter, obj)

          {:ok, {:accessor, nil, _}} ->
            :undefined

          {:ok, val} ->
            val

          :error ->
            case Map.fetch(map, idx) do
              {:ok, val} ->
                val

              :error when is_binary(key) or is_binary(idx) ->
                Get.get(obj, if(is_binary(key), do: key, else: idx))

              :error when is_tuple(key) ->
                Get.get(obj, key)

              :error ->
                :undefined
            end
        end

      {:shape, _, _, _, _} when is_binary(idx) or is_integer(idx) or is_tuple(idx) ->
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

  def get_element(%QuickBEAM.VM.Function{} = fun, key),
    do: Get.get(fun, PropertyKey.normalize(key))

  def get_element({:closure, _, %QuickBEAM.VM.Function{}} = closure, key),
    do: Get.get(closure, PropertyKey.normalize(key))

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

  def get_element({:builtin, _, _} = b, key) when is_integer(key),
    do: Get.get(b, Integer.to_string(key))

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

  def get_element({:regexp, _, _, _} = regexp, key) do
    Get.get(regexp, PropertyKey.normalize(key))
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

  @doc "Writes an indexed JavaScript element."
  def put_element({:builtin, _, _} = builtin, key, val) do
    put(builtin, PropertyKey.normalize(key), val)
  end

  def put_element(%QuickBEAM.VM.Function{} = fun, key, val) do
    put(fun, PropertyKey.normalize(key), val)
  end

  def put_element({:closure, _, %QuickBEAM.VM.Function{}} = closure, key, val) do
    put(closure, PropertyKey.normalize(key), val)
  end

  def put_element({:regexp, _, _, _} = regexp, key, val) do
    put(regexp, PropertyKey.normalize(key), val)
  end

  def put_element({:obj, ref} = obj, key, val) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} when is_integer(key) ->
        Runtime.TypedArray.set_element(obj, key, val)

      {:qb_arr, arr} ->
        case PropertyKey.array_index(key) do
          {:ok, i} ->
            put_array_index(obj, ref, arr, i, val)

          :error ->
            case PropertyKey.normalize(key) do
              "length" -> put(obj, "length", val)
              prop_key -> put_array_named_property(obj, ref, prop_key, val)
            end
        end

      list when is_list(list) ->
        case PropertyKey.array_index(key) do
          {:ok, i} when i < length(list) ->
            put_list_index(obj, ref, list, i, val)

          {:ok, i} ->
            put_list_index(obj, ref, list, i, val)

          :error ->
            case PropertyKey.normalize(key) do
              "length" -> put(obj, "length", val)
              prop_key -> put_array_named_property(obj, ref, prop_key, val)
            end
        end

      map when is_map(map) ->
        str_key =
          case key do
            {:symbol, _, _} -> key
            {:symbol, _} -> key
            k when is_float(k) and k == trunc(k) and k >= 0 -> Integer.to_string(trunc(k))
            _ -> Values.stringify(key)
          end

        if set(obj, str_key, val, obj) == false, do: reject_failed_write!()

      nil ->
        :ok
    end
  end

  def put_element(_, _, _), do: :ok

  defp put_array_index(obj, ref, arr, i, val) do
    key = Integer.to_string(i)

    case Heap.get_array_prop(ref, key) do
      {:accessor, _getter, setter} when setter != nil ->
        invoke_setter(setter, val, obj)

      {:accessor, _getter, nil} ->
        reject_failed_write!()

      _ ->
        cond do
          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            reject_failed_write!()

          i >= :array.size(arr) and Heap.get_array_prop(ref, "__arguments__") == true ->
            Heap.put_array_prop(ref, key, val)

          i >= :array.size(arr) and proto_has_setter?(i) ->
            invoke_proto_setter(obj, i, val)

          Heap.array_get(ref, i) == :undefined and Heap.get_prop_desc(ref, key) == nil and
              proto_has_setter?(i) ->
            invoke_proto_setter(obj, i, val)

          i >= :array.size(arr) and huge_length_growth?(:array.size(arr), i + 1) ->
            Heap.put_array_prop(ref, key, val)

            Heap.put_array_prop(
              ref,
              "length",
              max(virtual_array_length(ref) || :array.size(arr), i + 1)
            )

          true ->
            Heap.array_set(ref, i, val)
            mark_undefined_array_write(ref, key, val)
        end
    end
  end

  defp mark_undefined_array_write(ref, key, :undefined),
    do: Heap.put_prop_desc(ref, key, PropertyDescriptor.enumerable_data())

  defp mark_undefined_array_write(_ref, _key, _val), do: :ok

  defp put_list_index(obj, ref, list, i, val) do
    key = Integer.to_string(i)

    case Heap.get_array_prop(ref, key) do
      {:accessor, _getter, setter} when setter != nil ->
        invoke_setter(setter, val, obj)

      {:accessor, _getter, nil} ->
        reject_failed_write!()

      _ ->
        cond do
          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            reject_failed_write!()

          proto_has_setter?(i) ->
            invoke_proto_setter(obj, i, val)

          i < length(list) ->
            Heap.put_obj(ref, List.replace_at(list, i, val))
            mark_undefined_array_write(ref, key, val)

          Heap.get_array_prop(ref, "__arguments__") == true ->
            Heap.put_array_prop(ref, key, val)

          true ->
            padded = list ++ List.duplicate(:undefined, i - length(list)) ++ [val]
            Heap.put_obj(ref, padded)
        end
    end
  end

  @doc "Defines an array element and descriptor metadata."
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
              Heap.put_prop_desc(ref, Integer.to_string(i), PropertyDescriptor.enumerable_data())

            is_list(stored) ->
              i = if is_integer(idx), do: idx, else: Runtime.to_int(idx)
              Heap.put_obj(ref, set_list_at(stored, i, val))
              Heap.put_prop_desc(ref, Integer.to_string(i), PropertyDescriptor.enumerable_data())

            is_map(stored) ->
              key = PropertyKey.normalize(idx)

              stored =
                if key == proto() and Heap.get_prop_desc(ref, key) == nil and
                     Map.has_key?(stored, proto()) do
                  Map.put(stored, :__internal_proto__, Map.get(stored, proto()))
                else
                  stored
                end

              Heap.put_obj_key(ref, stored, key, val)
              Heap.put_prop_desc(ref, key, PropertyDescriptor.enumerable_data())

            true ->
              :ok
          end

          {:obj, ref}

        %QuickBEAM.VM.Function{} = ctor ->
          Heap.put_ctor_static(ctor, PropertyKey.normalize(idx), val)
          ctor

        {:closure, _, %QuickBEAM.VM.Function{}} = ctor ->
          Heap.put_ctor_static(ctor, PropertyKey.normalize(idx), val)
          ctor

        {:builtin, _, _} = ctor ->
          Heap.put_ctor_static(ctor, PropertyKey.normalize(idx), val)
          ctor

        _ ->
          obj
      end

    {idx, obj2}
  end

  @doc "Returns a list with an index updated, padding holes with `:undefined` as needed."
  def set_list_at(list, i, val) when is_integer(i) and i >= 0 and i < length(list),
    do: List.replace_at(list, i, val)

  def set_list_at(list, i, val) when is_integer(i) and i >= 0,
    do: list ++ List.duplicate(:undefined, max(0, i - length(list))) ++ [val]

  defp restricted_function_property?({:bound, _, _, _, _}), do: true

  defp restricted_function_property?(%QuickBEAM.VM.Function{is_strict_mode: true}), do: true

  defp restricted_function_property?({:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}),
    do: true

  defp restricted_function_property?(_), do: false

  defp reject_failed_write! do
    if Semantics.strict_mode?(), do: JSThrow.type_error!("Cannot assign to read only property")
    :ok
  end

  defp validate_proxy_set_invariant({:obj, target_ref} = target, key, val, trap_result) do
    if Values.truthy?(trap_result) do
      desc = Heap.get_prop_desc(target_ref, key)
      target_value = Get.get(target, key)

      cond do
        match?(%{configurable: false, writable: false}, desc) and val !== target_value ->
          JSThrow.type_error!("proxy set trap violates invariant")

        match?(%{configurable: false}, desc) and match?({:accessor, _, nil}, target_value) ->
          JSThrow.type_error!("proxy set trap violates invariant")

        true ->
          trap_result
      end
    else
      trap_result
    end
  end

  defp validate_proxy_set_invariant(_target, _key, _val, trap_result), do: trap_result

  defp sync_global_this?(obj, key, val) when is_binary(key) do
    case Heap.get_ctx() do
      %{globals: %{"globalThis" => ^obj}} ->
        globals = Heap.get_persistent_globals() || %{}
        Heap.put_persistent_globals(Map.put(globals, key, val))

      _ ->
        :ok
    end
  end

  defp sync_global_this?(_obj, _key, _val), do: :ok
end
