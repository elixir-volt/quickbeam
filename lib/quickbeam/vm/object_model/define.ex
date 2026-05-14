defmodule QuickBEAM.VM.ObjectModel.Define do
  @moduledoc "JavaScript [[DefineOwnProperty]] semantics for ordinary, proxy, array-like, and typed-array objects."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{ArrayExotic, Get, PropertyDescriptor, Semantics}
  alias QuickBEAM.VM.Runtime.TypedArray

  def property({:obj, ref} = obj, key, desc_obj, raw_desc) do
    desc = if is_map(raw_desc), do: raw_desc, else: %{}
    prop_name = property_name(key)
    existing = Heap.get_obj(ref, %{})

    if is_map(existing) and Map.has_key?(existing, proxy_target()) do
      throw({:early_return, proxy_property(obj, existing, key, prop_name, desc_obj)})
    end

    if non_extensible_new_property?(ref, existing, prop_name) or
         incompatible_existing_descriptor?(ref, existing, prop_name, desc) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    define_typed_array_index_property(obj, ref, existing, prop_name, desc)

    fields = descriptor_fields(desc_obj, desc)
    validate_descriptor_fields!(fields)

    if array_prototype_length_property?(existing, prop_name) do
      throw({:early_return, define_array_prototype_length!(obj, ref, desc, fields)})
    end

    case ArrayExotic.define_own_property(obj, ref, existing, prop_name, desc_obj, desc, fields) do
      :not_array -> :ok
      defined_obj -> throw({:early_return, defined_obj})
    end

    define_map_property(ref, existing, prop_name, desc_obj, desc, fields)
    obj
  catch
    {:early_return, val} -> val
  end

  defp property_name(key) do
    case key do
      k when is_binary(k) -> k
      {:symbol, _} -> key
      {:symbol, _, _} -> key
      _ -> Values.stringify(key)
    end
  end

  defp array_prototype_length_property?({:shape, _shape_id, offsets, _vals, _proto}, "length") do
    Map.has_key?(offsets, "constructor") and Map.has_key?(offsets, "push") and
      Map.has_key?(offsets, "pop")
  end

  defp array_prototype_length_property?(map, "length") when is_map(map) do
    Map.has_key?(map, "constructor") and Map.has_key?(map, "push") and Map.has_key?(map, "pop")
  end

  defp array_prototype_length_property?(_, _), do: false

  defp define_array_prototype_length!(obj, ref, desc, fields) do
    current =
      Heap.get_prop_desc(ref, "length") ||
        PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: false)

    cond do
      Map.get(desc, "configurable") == true ->
        throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

      Map.get(desc, "enumerable") == true ->
        throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

      current.writable == false and Map.get(desc, "writable") == true ->
        throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

      current.writable == false and fields.value_present ->
        throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

      true ->
        if fields.value_present do
          Heap.put_array_prop(ref, "length", array_length_value!(fields.value))
        end

        writable = Map.get(desc, "writable", current.writable)

        Heap.put_prop_desc(ref, "length", %{
          writable: writable,
          enumerable: false,
          configurable: false
        })

        obj
    end
  end

  defp array_length_value!(value) do
    number_len = Values.to_number(value)
    new_len = Values.to_uint32(value)

    if number_len == :nan or new_len != trunc(new_len) or new_len != number_len do
      throw({:js_throw, Heap.make_error("Invalid array length", "RangeError")})
    end

    new_len
  end

  defp proxy_property(proxy, proxy_map, key, prop_name, desc_obj) do
    target = Map.fetch!(proxy_map, proxy_target())
    handler = Map.fetch!(proxy_map, proxy_handler())
    trap = Get.get(handler, "defineProperty")

    cond do
      trap == :undefined or trap == nil ->
        property(target, key, desc_obj, descriptor_map(desc_obj))
        proxy

      not Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target, prop_name, desc_obj])) ->
        throw(
          {:js_throw, Heap.make_error("proxy defineProperty trap returned false", "TypeError")}
        )

      proxy_define_property_invariant_violation?(target, prop_name) ->
        throw(
          {:js_throw,
           Heap.make_error("proxy defineProperty trap violates invariant", "TypeError")}
        )

      true ->
        proxy
    end
  end

  defp descriptor_map({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp descriptor_map(_), do: %{}

  defp proxy_define_property_invariant_violation?({:obj, target_ref}, prop_name) do
    existing = Heap.get_obj(target_ref, %{})
    non_extensible_new_property?(target_ref, existing, prop_name)
  end

  defp proxy_define_property_invariant_violation?(_target, _prop_name), do: false

  defp define_typed_array_index_property(obj, _ref, existing, prop_name, desc) do
    if is_map(existing) and Map.get(existing, typed_array()) do
      case Integer.parse(prop_name) do
        {idx, ""} when idx >= 0 ->
          if idx >= TypedArray.element_count(obj) do
            throw({:js_throw, Heap.make_error("Invalid typed array index", "TypeError")})
          end

          val = Map.get(desc, "value")
          if val != nil, do: TypedArray.set_element(obj, idx, val)
          throw({:early_return, obj})

        _ ->
          :ok
      end
    end
  end

  defp descriptor_fields(desc_obj, desc) do
    %{
      getter_present: PropertyDescriptor.present?(desc_obj, desc, "get"),
      setter_present: PropertyDescriptor.present?(desc_obj, desc, "set"),
      value_present: PropertyDescriptor.present?(desc_obj, desc, "value"),
      writable_present: PropertyDescriptor.present?(desc_obj, desc, "writable"),
      getter: PropertyDescriptor.field(desc_obj, desc, "get", nil),
      setter: PropertyDescriptor.field(desc_obj, desc, "set", nil),
      value: PropertyDescriptor.field(desc_obj, desc, "value", :undefined)
    }
  end

  defp validate_descriptor_fields!(fields) do
    if (fields.getter_present or fields.setter_present) and
         (fields.value_present or fields.writable_present) do
      throw({:js_throw, Heap.make_error("Invalid property descriptor", "TypeError")})
    end

    if fields.getter_present and fields.getter != :undefined and
         not QuickBEAM.VM.Builtin.callable?(fields.getter) do
      throw({:js_throw, Heap.make_error("Getter must be callable", "TypeError")})
    end

    if fields.setter_present and fields.setter != :undefined and
         not QuickBEAM.VM.Builtin.callable?(fields.setter) do
      throw({:js_throw, Heap.make_error("Setter must be callable", "TypeError")})
    end
  end

  defp define_map_property(ref, existing, prop_name, desc_obj, desc, fields) do
    existing_value = Map.get(existing, prop_name, :undefined)
    property_exists? = Map.has_key?(existing, prop_name)

    cond do
      fields.getter_present or fields.setter_present ->
        {old_get, old_set} = accessor_pair(existing_value)
        new_get = PropertyDescriptor.accessor_slot(fields.getter_present, fields.getter, old_get)
        new_set = PropertyDescriptor.accessor_slot(fields.setter_present, fields.setter, old_set)
        Heap.put_obj_key(ref, existing, prop_name, {:accessor, new_get, new_set})

      fields.value_present or fields.writable_present or not property_exists? ->
        val = PropertyDescriptor.field(desc_obj, desc, "value", existing_value)
        Heap.put_obj_key(ref, existing, prop_name, val)

      true ->
        :ok
    end

    existing_flags = existing_map_attrs(ref, existing, prop_name)
    Heap.put_prop_desc(ref, prop_name, descriptor_attrs(desc_obj, desc, existing_flags, false))
  end

  defp existing_map_attrs(ref, existing, prop_name) do
    Heap.get_prop_desc(ref, prop_name) ||
      if Map.has_key?(existing, prop_name) do
        PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)
      end
  end

  defp accessor_pair({:accessor, getter, setter}), do: {getter, setter}
  defp accessor_pair(_), do: {nil, nil}

  defp descriptor_attrs(desc_obj, desc, existing_attrs, default),
    do: Semantics.descriptor_attrs(desc_obj, desc, existing_attrs, default)

  defp non_extensible_new_property?(ref, existing, prop_name) do
    not Heap.extensible?(ref) and not property_present?(existing, prop_name)
  end

  defp property_present?(map, prop_name) when is_map(map) do
    raw_key = Semantics.parse_array_index_key(prop_name)
    Map.has_key?(map, prop_name) or (raw_key != :error and Map.has_key?(map, raw_key))
  end

  defp property_present?(list, prop_name) when is_list(list) do
    case Integer.parse(prop_name) do
      {idx, ""} when idx >= 0 -> idx < length(list)
      _ -> false
    end
  end

  defp property_present?({:qb_arr, arr}, prop_name) do
    case Integer.parse(prop_name) do
      {idx, ""} when idx >= 0 -> idx < :array.size(arr)
      _ -> false
    end
  end

  defp property_present?(_existing, _prop_name), do: false

  defp incompatible_existing_descriptor?(ref, existing, prop_name, desc) when is_map(existing) do
    current_desc = Heap.get_prop_desc(ref, prop_name)
    current_value = Map.get(existing, prop_name, :undefined)

    cond do
      current_desc in [nil, :deleted] ->
        false

      current_desc.configurable == false and Map.get(desc, "configurable") == true ->
        true

      current_desc.configurable == false and Map.has_key?(desc, "enumerable") and
          Map.get(desc, "enumerable") != current_desc.enumerable ->
        true

      current_desc.configurable == false and
          accessor_data_descriptor_conflict?(current_value, desc) ->
        true

      current_desc.configurable == false and accessor_descriptor_conflict?(current_value, desc) ->
        true

      current_desc.configurable == false and current_desc.writable == false and
          Map.get(desc, "writable") == true ->
        true

      current_desc.configurable == false and not match?({:accessor, _, _}, current_value) and
        current_desc.writable == false and Map.has_key?(desc, "value") and
          not Semantics.same_value?(Map.get(desc, "value"), current_value) ->
        true

      true ->
        false
    end
  end

  defp incompatible_existing_descriptor?(_ref, _existing, _prop_name, _desc), do: false

  defp accessor_data_descriptor_conflict?({:accessor, _, _}, desc) do
    Map.has_key?(desc, "value") or Map.has_key?(desc, "writable")
  end

  defp accessor_data_descriptor_conflict?(_data_value, desc) do
    Map.has_key?(desc, "get") or Map.has_key?(desc, "set")
  end

  defp accessor_descriptor_conflict?({:accessor, old_get, old_set}, desc) do
    (Map.has_key?(desc, "get") and not same_accessor_slot?(Map.get(desc, "get"), old_get)) or
      (Map.has_key?(desc, "set") and not same_accessor_slot?(Map.get(desc, "set"), old_set))
  end

  defp accessor_descriptor_conflict?(_data_value, _desc), do: false

  defp same_accessor_slot?(:undefined, nil), do: true
  defp same_accessor_slot?(nil, nil), do: true
  defp same_accessor_slot?(a, b), do: a == b
end
