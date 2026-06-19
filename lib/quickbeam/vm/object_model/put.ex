defmodule QuickBEAM.VM.ObjectModel.Put do
  @moduledoc "Property write operations: set, define, and delete for JS objects, arrays, proxies, getters, and setters."
  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_symbol: 1]

  alias QuickBEAM.VM.Execution.{
    ClosureCells,
    DefinitionState,
    PrimitivePrototypeState,
    RegexpState,
    SetterState
  }

  alias QuickBEAM.VM.{Heap, Runtime, RuntimeState, Value}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime.TypedArray
  alias QuickBEAM.VM.Runtime.TypedArrayCoercion

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Get,
    HasProperty,
    OwnProperty,
    InternalMethods,
    PropertyDescriptor,
    ProxySet,
    PropertyKey,
    Semantics,
    WrappedPrimitive
  }

  @compile {:inline, has_property: 2, get_element: 2, set_list_at: 3}

  @max_array_length 4_294_967_295

  defp shape_put(ref, key, val) do
    cache_primitive_then_override(ref, key, val)
    Heap.put_obj_key(ref, key, val)
  end

  @doc "Writes a field using the fast shape path when possible."
  def put_field({:obj, ref}, key, val) do
    key = normalize_key(key)
    cache_primitive_then_override(ref, key, val)
    raw = Heap.get_obj_raw(ref)

    if Heap.shape?(raw), do: shape_put(ref, key, val), else: put({:obj, ref}, key, val)
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

  defp array_prototype_raw?(raw), do: Semantics.array_prototype_object?(raw)

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
    raw = Heap.get_obj_raw(ref)

    cond do
      array_prototype_raw?(raw) ->
        put_array_prototype_length(ref, val)

      is_map(raw) ->
        case Heap.raw_fetch(raw, "length") do
          {:ok, {:accessor, _getter, setter}} when setter != nil ->
            invoke_setter(setter, val, obj)

          {:ok, {:accessor, _getter, nil}} ->
            reject_failed_write!()

          _ ->
            put_length_property(obj, ref, val)
        end

      true ->
        put_length_property(obj, ref, val)
    end
  end

  def put({:obj, ref} = obj, key, val) do
    key = normalize_key(key)
    sync_global_this?(obj, key, val)

    case Heap.get_obj_raw(ref) do
      {:qb_arr, _} ->
        put_array_key(ref, key, val)

      %{proxy_target() => _target, proxy_handler() => _handler} ->
        ProxySet.dispatch(obj, key, val, obj, fn target, key, value, _receiver ->
          put(target, key, value)
        end)

      list when is_list(list) ->
        put_array_key(ref, key, val)

      map when is_map(map) ->
        cond do
          Map.get(map, typed_array()) == true and
              typed_array_integer_put(obj, key, val) != :not_integer_index ->
            :ok

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
            cache_primitive_then_override(map, key, val)
            Heap.put_obj_key(ref, map, key, val)

          match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            :ok

          true ->
            cache_primitive_then_override(map, key, val)
            Heap.put_obj_key(ref, map, key, val)
        end

      raw when is_tuple(raw) ->
        if Heap.shape?(raw), do: put_shape_object(obj, ref, raw, key, val), else: :ok

      _ ->
        :ok
    end
  end

  def put(%QuickBEAM.VM.Function{} = f, key, val), do: put_callable_property(f, key, val)

  def put({:closure, _, %QuickBEAM.VM.Function{}} = c, key, val),
    do: put_callable_property(c, key, val)

  def put({:builtin, _, _} = b, key, val), do: put_callable_property(b, key, val)
  def put({:bound, _, _, _, _} = b, key, val), do: put_callable_property(b, key, val)

  def put({:regexp, _, _, ref} = regexp, key, val) do
    key = normalize_key(key)

    desc = Heap.get_prop_desc(ref, key)

    cond do
      match?(%{writable: false}, desc) ->
        reject_failed_write!()

      key in [
        "flags",
        "hasIndices",
        "global",
        "ignoreCase",
        "multiline",
        "dotAll",
        "unicode",
        "unicodeSets",
        "sticky"
      ] and desc == nil ->
        reject_failed_write!()

      not RegexpState.has_property?(ref, key) and not Heap.extensible?(regexp) ->
        reject_failed_write!()

      true ->
        RegexpState.put(ref, key, val)

        if desc == nil do
          Heap.put_prop_desc(ref, key, PropertyDescriptor.enumerable_data())
        end
    end
  end

  def put(_, _, _), do: :ok

  defp cache_primitive_then_override(ref, "then", val) when is_reference(ref) do
    Enum.each(["Boolean", "Number", "String", "Symbol"], fn name ->
      case Runtime.global_class_proto(name) do
        {:obj, ^ref} -> PrimitivePrototypeState.put_then(name, val)
        _ -> :ok
      end
    end)
  end

  defp cache_primitive_then_override(map, "then", val) when is_map(map) do
    case Map.get(map, "constructor") do
      {:builtin, name, _} when name in ["Boolean", "Number", "String", "Symbol"] ->
        PrimitivePrototypeState.put_then(name, val)

      _ ->
        :ok
    end
  end

  defp cache_primitive_then_override(_ref, "then", val) do
    Enum.each(["Boolean", "Number", "String", "Symbol"], fn name ->
      PrimitivePrototypeState.put_then(name, val)
    end)
  end

  defp cache_primitive_then_override(_map, _key, _val), do: :ok

  defp put_shape_object(obj, ref, raw, key, val) do
    case Heap.raw_accessor_setter(raw, key) do
      {:ok, setter} ->
        invoke_setter(setter, val, obj)

      :error ->
        cond do
          Heap.frozen?(ref) ->
            :ok

          key == "__proto__" ->
            Heap.put_shape_proto(ref, val)

          wrapped_raw_string_virtual_readonly?(raw, key) ->
            :ok

          not Heap.raw_has_key?(raw, key) and
              proto_has_setter_property?(Heap.shape_proto(raw), key) ->
            set(Heap.shape_proto(raw), key, val, obj)

          not Heap.raw_has_key?(raw, key) and
              proto_has_getter_only_property?(Heap.shape_proto(raw), key) ->
            :ok

          not Heap.extensible?(ref) and not Heap.raw_has_key?(raw, key) ->
            :ok

          is_symbol(key) ->
            Heap.put_obj_key(ref, Heap.shape_to_map(raw), key, val)

          true ->
            shape_put(ref, key, val)
        end
    end
  end

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
      {:qb_arr, _} = array ->
        resize_array(ref, array, array_length_value!(val))

      data when is_list(data) ->
        resize_array(ref, data, array_length_value!(val))

      raw when is_tuple(raw) ->
        if Heap.shape?(raw) and wrapped_raw_string_virtual_readonly?(raw, "length") do
          :ok
        else
          shape_put(ref, "length", val)
        end

      map when is_map(map) ->
        case WrappedPrimitive.value(map, :string) do
          {:ok, string} when is_binary(string) -> :ok
          _ -> Heap.put_obj_key(ref, map, "length", val)
        end

      _ ->
        :ok
    end
  end

  defp wrapped_raw_string_virtual_readonly?(raw, "length") do
    match?(
      {:ok, string} when is_binary(string),
      Heap.raw_fetch(raw, WrappedPrimitive.slot(:string))
    )
  end

  defp wrapped_raw_string_virtual_readonly?(raw, key) do
    with {:ok, string} when is_binary(string) <-
           Heap.raw_fetch(raw, WrappedPrimitive.slot(:string)),
         {:ok, index} <- PropertyKey.array_index(key) do
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
         {:ok, index} <- PropertyKey.array_index(key) do
      index >= 0 and index < Get.string_length(string)
    else
      _ -> false
    end
  end

  defp wrapped_string_virtual_readonly?(_map, _key), do: false

  @doc "Writes a property using an explicit receiver, for Reflect.set semantics."
  def set(target, key, val, receiver), do: InternalMethods.set(target, key, val, receiver)

  def ordinary_set({:obj, ref}, key, val, receiver) do
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

  def ordinary_set({:regexp, _, _, _} = regexp, key, val, _receiver) do
    key = normalize_key(key)

    if regexp_getter_only_property?(regexp, key) do
      false
    else
      put(regexp, key, val)
      true
    end
  end

  def ordinary_set(%QuickBEAM.VM.Function{} = fun, key, val, _receiver),
    do: ordinary_set_callable(fun, key, val)

  def ordinary_set({:closure, _, %QuickBEAM.VM.Function{}} = fun, key, val, _receiver),
    do: ordinary_set_callable(fun, key, val)

  def ordinary_set({:builtin, _, _} = fun, key, val, _receiver),
    do: ordinary_set_callable(fun, key, val)

  def ordinary_set({:bound, _, _, _, _} = fun, key, val, _receiver),
    do: ordinary_set_callable(fun, key, val)

  def ordinary_set(target, key, val, _receiver) do
    put(target, key, val)
    true
  end

  defp set_property(ref, raw, key, val, receiver) do
    case raw do
      %{proxy_target() => _proxy_target, proxy_handler() => _handler} ->
        set({:obj, ref}, key, val, receiver)

      {:qb_arr, _} = array ->
        set_array_property(ref, array, key, val, receiver)

      raw when is_tuple(raw) ->
        cond do
          Heap.shape?(raw) and match?({:ok, true}, Heap.raw_fetch(raw, typed_array())) ->
            case typed_array_integer_set({:obj, ref}, key, val, receiver) do
              :not_integer_index -> set_shape_property(ref, raw, key, val, receiver)
              result -> result
            end

          Heap.shape?(raw) ->
            set_shape_property(ref, raw, key, val, receiver)

          true ->
            write_receiver(receiver, key, val)
        end

      list when is_list(list) ->
        set_array_property(ref, list, key, val, receiver)

      map when is_map(map) ->
        case typed_array_set_result(map, {:obj, ref}, key, val, receiver) do
          :not_integer_index ->
            cond do
              typed_array_metadata_slot_without_own_property?(ref, map, key) ->
                false

              wrapped_string_virtual_readonly?(map, key) ->
                false

              true ->
                case Map.get(map, key) do
                  nil ->
                    if prototype_present?(Map.get(map, proto())) do
                      set(Map.get(map, proto()), key, val, receiver)
                    else
                      write_receiver(receiver, key, val)
                    end

                  {:accessor, _, setter} when setter != nil ->
                    invoke_setter(setter, val, receiver)
                    true

                  {:accessor, _, nil} ->
                    false

                  _ ->
                    if match?(%{writable: false}, Heap.get_prop_desc(ref, key)) do
                      false
                    else
                      write_receiver(receiver, key, val)
                    end
                end
            end

          result ->
            result
        end

      _ ->
        write_receiver(receiver, key, val)
    end
  end

  defp set_shape_property(ref, raw, key, val, receiver) do
    case Heap.raw_accessor_setter(raw, key) do
      {:ok, setter} ->
        invoke_setter(setter, val, receiver)
        true

      :error ->
        cond do
          Heap.raw_has_key?(raw, key) and match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            false

          Heap.raw_has_key?(raw, key) ->
            write_receiver(receiver, key, val)

          prototype_present?(Heap.shape_proto(raw)) ->
            set(Heap.shape_proto(raw), key, val, receiver)

          true ->
            write_receiver(receiver, key, val)
        end
    end
  end

  defp set_array_property(ref, array, key, val, receiver) do
    case PropertyKey.array_index(key) do
      {:ok, idx} ->
        cond do
          array_index_present?(ref, array, idx) ->
            write_receiver(receiver, key, val)

          prototype_present?(Heap.get_array_proto(ref)) ->
            set(Heap.get_array_proto(ref), key, val, receiver)

          true ->
            write_receiver(receiver, key, val)
        end

      :error ->
        cond do
          Heap.get_array_prop(ref, key) != nil ->
            write_receiver(receiver, key, val)

          prototype_present?(Heap.get_array_proto(ref)) ->
            set(Heap.get_array_proto(ref), key, val, receiver)

          true ->
            write_receiver(receiver, key, val)
        end
    end
  end

  defp array_index_present?(ref, {:qb_arr, _}, idx),
    do:
      Heap.array_get(ref, idx) != :undefined or
        Heap.get_prop_desc(ref, Integer.to_string(idx)) != nil

  defp array_index_present?(ref, list, idx) when is_list(list) do
    (idx < length(list) and Enum.at(list, idx) != :undefined) or
      Heap.get_prop_desc(ref, Integer.to_string(idx)) != nil
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

        try do
          Define.property(receiver, key, Heap.wrap(desc), desc)
          true
        catch
          {:js_throw, reason} ->
            if define_property_failure?(reason), do: false, else: throw({:js_throw, reason})
        end

      raw when is_tuple(raw) ->
        cond do
          Heap.shape?(raw) and match?({:ok, true}, Heap.raw_fetch(raw, typed_array())) ->
            write_typed_array_receiver(receiver, key, val)

          not Heap.shape?(raw) ->
            put(receiver, key, val)
            true

          Heap.raw_accessor?(raw, key) ->
            false

          Heap.raw_has_key?(raw, key) and match?(%{writable: false}, Heap.get_prop_desc(ref, key)) ->
            false

          Heap.raw_has_key?(raw, key) ->
            define_receiver_property(receiver, key, val)

          Heap.extensible?(ref) ->
            define_receiver_property(receiver, key, val)

          true ->
            false
        end

      map when is_map(map) ->
        if Map.get(map, typed_array()) == true do
          write_typed_array_receiver(receiver, key, val)
        else
          case Map.get(map, key) do
            nil ->
              if Heap.extensible?(ref) do
                define_receiver_property(receiver, key, val)
              else
                false
              end

            {:accessor, _, _} ->
              false

            _ ->
              if match?(%{writable: false}, Heap.get_prop_desc(ref, key)) do
                false
              else
                define_receiver_property(receiver, key, val)
              end
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

  defp define_receiver_property(receiver, key, val) do
    desc = receiver_write_descriptor(receiver, key, val)

    try do
      Define.property(receiver, key, Heap.wrap(desc), desc)
      true
    catch
      {:js_throw, reason} ->
        if define_property_failure?(reason), do: false, else: throw({:js_throw, reason})
    end
  end

  defp write_typed_array_receiver(receiver, key, val) do
    case Runtime.TypedArray.integer_index_key(key) do
      {:ok, idx} ->
        if idx < Runtime.TypedArray.element_count(receiver) do
          Runtime.TypedArray.set_element(receiver, idx, val)
          true
        else
          false
        end

      :invalid ->
        false

      :not_integer_index ->
        put(receiver, key, val)
        true
    end
  end

  defp ordinary_set_callable(fun, key, val) do
    key = normalize_key(key)

    cond do
      key in ["length", "name"] and not match?(%{writable: true}, callable_prop_desc(fun, key)) ->
        false

      match?(%{writable: false}, callable_prop_desc(fun, key)) ->
        false

      true ->
        put(fun, key, val)
        true
    end
  end

  defp define_property_failure?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"message" => "Cannot define property"} -> true
      _ -> false
    end
  end

  defp define_property_failure?(_), do: false

  defp regexp_getter_only_property?(_regexp, key) do
    key in [
      "source",
      "flags",
      "hasIndices",
      "global",
      "ignoreCase",
      "multiline",
      "dotAll",
      "unicode",
      "unicodeSets",
      "sticky"
    ]
  end

  defp typed_array_metadata_slot_without_own_property?(ref, map, key) do
    Map.get(map, typed_array()) == true and TypedArray.metadata_key?(key) and
      Heap.get_prop_desc(ref, key) == nil
  end

  defp receiver_write_descriptor(receiver, key, val) do
    case OwnProperty.descriptor(receiver, key) do
      :undefined ->
        %{"value" => val, "writable" => true, "enumerable" => true, "configurable" => true}

      _descriptor ->
        %{"value" => val}
    end
  end

  defp receiver_object?(value), do: Value.object_like?(value)

  def put(target, key, val, true), do: put(target, key, val)

  def put({:obj, ref}, key, val, false) do
    case Heap.get_obj_raw(ref) do
      raw when is_tuple(raw) ->
        if Heap.shape?(raw) and not Heap.frozen?(ref) do
          shape_put(ref, key, val)
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
      QuickBEAM.VM.Builtin.callable?(callable) and key in ["length", "name"] and
        not match?(%{writable: true}, callable_prop_desc(callable, key)) and
          not static_class_method_definition?(callable, key) ->
        reject_failed_write!()

      key in ["caller", "arguments"] and restricted_function_property?(callable) ->
        JSThrow.type_error!("'caller' and 'arguments' are restricted function properties")

      match?({:accessor, _, nil}, Map.get(statics, key)) ->
        reject_failed_write!()

      match?({:accessor, _, setter} when not is_nil(setter), Map.get(statics, key)) ->
        {:accessor, _, setter} = Map.fetch!(statics, key)
        Invocation.invoke_with_receiver(setter, [val], callable)
        :ok

      match?(%{writable: false}, callable_prop_desc(callable, key)) or
        inherited_object_property_readonly?(callable, key) or
          inherited_object_getter_only?(callable, key) ->
        :ok

      not own? and function_proto_has_setter?(key) ->
        invoke_function_proto_setter(callable, key, val)

      not own? and function_proto_has_getter_only?(key) ->
        :ok

      not own? and not Heap.extensible?(callable) ->
        reject_failed_write!()

      true ->
        Heap.put_ctor_static(callable, key, val)
    end
  end

  defp typed_array_integer_put(obj, key, val) do
    case Runtime.TypedArray.integer_index_key(key) do
      {:ok, idx} ->
        coerced = coerce_typed_array_set_value(obj, val)

        if idx < Runtime.TypedArray.element_count(obj) do
          Runtime.TypedArray.set_element(obj, idx, coerced)
        end

        :ok

      :invalid ->
        :ok

      :not_integer_index ->
        :not_integer_index
    end
  end

  defp typed_array_set_result(%{typed_array() => true}, obj, key, val, receiver),
    do: typed_array_integer_set(obj, key, val, receiver)

  defp typed_array_set_result(_map, _obj, _key, _val, _receiver), do: :not_integer_index

  defp typed_array_integer_set(obj, key, val, receiver) do
    case Runtime.TypedArray.integer_index_key(key) do
      {:ok, idx} ->
        cond do
          receiver != obj and idx < Runtime.TypedArray.element_count(obj) ->
            write_receiver(receiver, key, val)

          receiver == obj and idx < Runtime.TypedArray.element_count(obj) ->
            Runtime.TypedArray.set_element(obj, idx, val)
            :ok

          receiver == obj ->
            coerced = coerce_typed_array_set_value(obj, val)

            if idx < Runtime.TypedArray.element_count(obj) do
              Runtime.TypedArray.set_element(obj, idx, coerced)
            end

            :ok

          true ->
            false
        end

      :invalid ->
        :ok

      :not_integer_index ->
        :not_integer_index
    end
  end

  defp coerce_typed_array_set_value({:obj, ref}, val) do
    case Heap.get_obj(ref, %{}) do
      %{type_key() => type} -> TypedArrayCoercion.element_value(val, type)
      _ -> :ok
    end
  end

  defp normalize_key(k), do: PropertyKey.normalize(k)

  defp callable_prop_desc(callable, key),
    do: Heap.get_prop_desc(callable, key) || Heap.get_ctor_prop_desc(callable, key)

  defp static_class_method_definition?(callable, _key),
    do: DefinitionState.static_method_definition?(callable)

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

          not array_named_property_present?(ref, key) and not Heap.extensible?(ref) ->
            reject_failed_write!()

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

  def put_getter(target, key, fun), do: put_ctor_getter(target, key, fun)

  def put_getter(target, key, fun, true), do: put_getter(target, key, fun)

  def put_getter({:obj, ref}, key, fun, false) do
    update_getter(ref, key, fun)
    Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true})
  end

  def put_getter(target, key, fun, _enumerable), do: put_ctor_getter(target, key, fun)

  @doc "Defines or replaces a JavaScript setter property."
  def put_setter({:obj, ref}, key, fun) do
    update_setter(ref, key, fun)
  end

  def put_setter(target, key, fun), do: put_ctor_setter(target, key, fun)

  def put_setter(target, key, fun, true), do: put_setter(target, key, fun)

  def put_setter({:obj, ref}, key, fun, false) do
    update_setter(ref, key, fun)
    Heap.put_prop_desc(ref, key, %{enumerable: false, configurable: true})
  end

  def put_setter(target, key, fun, _enumerable), do: put_ctor_setter(target, key, fun)

  defp put_ctor_getter(target, key, fun) do
    setter =
      case Map.get(Heap.get_ctor_statics(target), key) do
        {:accessor, _getter, setter} -> setter
        _ -> nil
      end

    Heap.put_ctor_static(target, key, {:accessor, fun, setter})
  end

  defp put_ctor_setter(target, key, fun) do
    getter =
      case Map.get(Heap.get_ctor_statics(target), key) do
        {:accessor, getter, _setter} -> getter
        _ -> nil
      end

    Heap.put_ctor_static(target, key, {:accessor, getter, fun})
  end

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

  defp prototype_proxy?({:obj, ref}) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => _target, proxy_handler() => _handler} -> true
      _ -> false
    end
  end

  defp prototype_proxy?(_), do: false

  defp prototype_present?(nil), do: false
  defp prototype_present?(:undefined), do: false
  defp prototype_present?(proto), do: Value.object_like?(proto)

  defp proto_has_setter_property?(nil, _key), do: false
  defp proto_has_setter_property?(:undefined, _key), do: false

  defp proto_has_setter_property?({:obj, ref}, key) do
    raw = Heap.get_obj_raw(ref)

    case Heap.raw_accessor_setter(raw, key) do
      {:ok, _setter} -> true
      :error -> proto_has_setter_property?(Heap.raw_proto(raw), key)
    end
  end

  defp proto_has_setter_property?(_proto_obj, _key), do: false

  defp proto_has_getter_only_property?(nil, _key), do: false
  defp proto_has_getter_only_property?(:undefined, _key), do: false

  defp proto_has_getter_only_property?({:obj, ref}, key) do
    raw = Heap.get_obj_raw(ref)

    if Heap.raw_getter_only?(raw, key),
      do: true,
      else: proto_has_getter_only_property?(Heap.raw_proto(raw), key)
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
    with %{globals: globals} <- RuntimeState.current(),
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
    raw = Heap.get_obj_raw(ref)

    case Heap.raw_fetch(raw, key) do
      {:ok, value} -> value
      :error -> find_proto_accessor(raw_next_proto(ref, raw), key)
    end
  end

  defp raw_next_proto(ref, raw) do
    Heap.raw_proto(raw) || object_proto_fallback(ref)
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

      raw when is_tuple(raw) and (is_binary(idx) or is_integer(idx) or is_tuple(idx)) ->
        if Heap.shape?(raw),
          do: Get.get(obj, if(is_integer(idx), do: Integer.to_string(idx), else: idx)),
          else: :undefined

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

  def get_element({:builtin, _, _} = b, {:symbol, _} = sym_key), do: Get.get(b, sym_key)

  def get_element({:builtin, _, _} = b, {:symbol, _, _} = sym_key),
    do: Get.get(b, PropertyKey.normalize(sym_key))

  def get_element({:regexp, _, _, _} = regexp, key) do
    Get.get(regexp, PropertyKey.normalize(key))
  end

  def get_element({:obj, _} = obj, {:symbol, _, _} = sym_key),
    do: Get.get(obj, PropertyKey.normalize(sym_key))

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

  def put_element({:bound, _, _, _, _} = bound, key, val) do
    put(bound, PropertyKey.normalize(key), val)
  end

  def put_element({:regexp, _, _, _} = regexp, key, val) do
    put(regexp, PropertyKey.normalize(key), val)
  end

  def put_element({:obj, ref} = obj, key, val) do
    case Heap.get_obj(ref) do
      %{typed_array() => true} ->
        case typed_array_integer_put(obj, key, val) do
          :not_integer_index -> put(obj, PropertyKey.normalize(key), val)
          :ok -> :ok
        end

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

        if Map.has_key?(map, "exec") and Map.has_key?(map, "test") and Map.has_key?(map, "source") and
             str_key == {:symbol, "Symbol.matchAll"} do
          RegexpState.put_match_all_override(val)
        end

        cache_primitive_then_override(ref, str_key, val)

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

          i >= :array.size(arr) and Heap.get_array_prop(ref, "__arguments__") == true and
              not Heap.extensible?(ref) ->
            reject_failed_write!()

          i >= :array.size(arr) and Heap.get_array_prop(ref, "__arguments__") == true ->
            Heap.put_array_prop(ref, key, val)

          i >= :array.size(arr) and not Heap.extensible?(ref) ->
            reject_failed_write!()

          i >= :array.size(arr) and proto_has_setter?(i) ->
            invoke_proto_setter(obj, i, val)

          not array_index_present?(ref, {:qb_arr, arr}, i) and
              prototype_proxy?(Heap.get_array_proto(ref)) ->
            set(Heap.get_array_proto(ref), key, val, obj)

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

          mapped_argument_write(ref, i, val) ->
            :ok

          true ->
            Heap.array_set(ref, i, val)
            mark_undefined_array_write(ref, key, val)
        end
    end
  end

  defp mapped_argument_write(ref, index, val) do
    case Heap.get_array_prop(ref, "__mapped_arguments__") do
      mapped when is_map(mapped) ->
        case Map.get(mapped, index) do
          {:cell, _} = cell ->
            ClosureCells.write(cell, val)
            true

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp mark_undefined_array_write(ref, key, :undefined) do
    if Heap.get_prop_desc(ref, key) == nil do
      Heap.put_prop_desc(ref, key, PropertyDescriptor.enumerable_data())
    end
  end

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

          not array_index_present?(ref, list, i) and prototype_proxy?(Heap.get_array_proto(ref)) ->
            set(Heap.get_array_proto(ref), key, val, obj)

          mapped_argument_write(ref, i, val) ->
            :ok

          i < length(list) ->
            Heap.put_obj(ref, List.replace_at(list, i, val))
            mark_undefined_array_write(ref, key, val)

          Heap.get_array_prop(ref, "__arguments__") == true and not Heap.extensible?(ref) ->
            reject_failed_write!()

          Heap.get_array_prop(ref, "__arguments__") == true ->
            Heap.put_array_prop(ref, key, val)

          not Heap.extensible?(ref) ->
            reject_failed_write!()

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
          define_callable_static_field(ctor, idx, val)

        {:closure, _, %QuickBEAM.VM.Function{}} = ctor ->
          define_callable_static_field(ctor, idx, val)

        {:builtin, _, _} = ctor ->
          define_callable_static_field(ctor, idx, val)

        _ ->
          obj
      end

    {idx, obj2}
  end

  defp define_callable_static_field(ctor, idx, val) do
    desc =
      Heap.wrap(%{
        "value" => val,
        "writable" => true,
        "enumerable" => true,
        "configurable" => true
      })

    key = PropertyKey.normalize(idx)
    Define.property(ctor, key, desc, Heap.get_obj(elem(desc, 1), %{}))
    ctor
  end

  @doc "Returns a list with an index updated, padding holes with `:undefined` as needed."
  def set_list_at(list, i, val) when is_integer(i) and i >= 0 and i < length(list),
    do: List.replace_at(list, i, val)

  def set_list_at(list, i, val) when is_integer(i) and i >= 0,
    do: list ++ List.duplicate(:undefined, max(0, i - length(list))) ++ [val]

  defp restricted_function_property?({:bound, _, _, _, _}), do: true

  defp restricted_function_property?(%QuickBEAM.VM.Function{func_kind: kind})
       when kind in [1, 2, 3], do: true

  defp restricted_function_property?({:closure, _, %QuickBEAM.VM.Function{func_kind: kind}})
       when kind in [1, 2, 3],
       do: true

  defp restricted_function_property?(fun), do: Value.strict_function?(fun)

  defp reject_failed_write! do
    if Semantics.strict_mode?(), do: JSThrow.type_error!("Cannot assign to read only property")
    :ok
  end

  defp sync_global_this?(obj, key, val) when is_binary(key) do
    case RuntimeState.current() do
      %{globals: %{"globalThis" => ^obj}} ->
        globals = Heap.get_persistent_globals() || %{}
        Heap.put_persistent_globals(Map.put(globals, key, val))

      _ ->
        :ok
    end
  end

  defp sync_global_this?(_obj, _key, _val), do: :ok
end
