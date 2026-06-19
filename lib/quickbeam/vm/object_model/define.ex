defmodule QuickBEAM.VM.ObjectModel.Define do
  @moduledoc "JavaScript [[DefineOwnProperty]] semantics for ordinary, proxy, array-like, and typed-array objects."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.Semantics.Values

  alias QuickBEAM.VM.ObjectModel.{
    ArrayExotic,
    Get,
    PropertyDescriptor,
    PropertyKey,
    ProxyDefine,
    Semantics,
    WrappedPrimitive
  }

  alias QuickBEAM.VM.Runtime.TypedArray

  def property(callable, key, desc_obj, raw_desc)
      when is_function(callable) or is_struct(callable) or
             (is_tuple(callable) and elem(callable, 0) in [:builtin, :closure, :bound]) do
    desc = if is_map(raw_desc), do: raw_desc, else: %{}
    prop_name = property_name(key)
    existing = Heap.get_ctor_statics(callable)

    if static_incompatible_descriptor?(callable, existing, prop_name, desc) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    fields = descriptor_fields(desc_obj, desc)
    validate_descriptor_fields!(fields)
    existing_value = Map.get(existing, prop_name, :undefined)

    cond do
      fields.getter_present or fields.setter_present ->
        {old_get, old_set} = accessor_pair(existing_value)
        new_get = PropertyDescriptor.accessor_slot(fields.getter_present, fields.getter, old_get)
        new_set = PropertyDescriptor.accessor_slot(fields.setter_present, fields.setter, old_set)
        Heap.put_ctor_static(callable, prop_name, {:accessor, new_get, new_set})

      fields.value_present or fields.writable_present or not Map.has_key?(existing, prop_name) ->
        Heap.put_ctor_static(
          callable,
          prop_name,
          PropertyDescriptor.field(desc_obj, desc, "value", existing_value)
        )

      true ->
        :ok
    end

    existing_attrs =
      Heap.get_prop_desc(callable, prop_name) || Heap.get_ctor_prop_desc(callable, prop_name)

    Heap.put_ctor_prop_desc(
      callable,
      prop_name,
      descriptor_attrs(desc_obj, desc, existing_attrs, false)
    )

    callable
  end

  def property({:regexp, _, _, ref} = regexp, key, desc_obj, raw_desc) do
    desc = if is_map(raw_desc), do: raw_desc, else: %{}
    prop_name = property_name(key)
    existing = RegexpState.get(ref)

    if non_extensible_new_property?(ref, existing, prop_name) or
         incompatible_existing_descriptor?(ref, existing, prop_name, desc) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    fields = descriptor_fields(desc_obj, desc)
    validate_descriptor_fields!(fields)

    existing_value = Map.get(existing, prop_name, :undefined)

    cond do
      fields.getter_present or fields.setter_present ->
        {old_get, old_set} = accessor_pair(existing_value)
        new_get = PropertyDescriptor.accessor_slot(fields.getter_present, fields.getter, old_get)
        new_set = PropertyDescriptor.accessor_slot(fields.setter_present, fields.setter, old_set)
        RegexpState.put(ref, prop_name, {:accessor, new_get, new_set})

      fields.value_present or fields.writable_present or
          not RegexpState.has_property?(ref, prop_name) ->
        RegexpState.put(
          ref,
          prop_name,
          PropertyDescriptor.field(desc_obj, desc, "value", existing_value)
        )

      true ->
        :ok
    end

    existing_attrs = existing_map_attrs(ref, existing, prop_name)
    Heap.put_prop_desc(ref, prop_name, descriptor_attrs(desc_obj, desc, existing_attrs, false))
    regexp
  end

  def property({:obj, ref} = obj, key, desc_obj, raw_desc) do
    desc = if is_map(raw_desc), do: raw_desc, else: %{}
    prop_name = property_name(key)
    existing = Heap.get_obj(ref, %{})

    if wrapped_string_virtual_incompatible?(existing, prop_name, desc) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    if is_map(existing) and Map.has_key?(existing, proxy_target()) do
      throw(
        {:early_return,
         ProxyDefine.dispatch(
           obj,
           key,
           prop_name,
           desc_obj,
           &property(&1, &2, &3, descriptor_map(&3)),
           &proxy_define_property_invariant_violation?/3
         )}
      )
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

  def create_data_property({:obj, ref} = obj, key, value) do
    prop_name = PropertyKey.normalize(key)
    existing = Heap.get_obj(ref, %{})

    cond do
      is_map(existing) and Map.has_key?(existing, proxy_target()) ->
        desc = data_property_descriptor(value)
        property(obj, prop_name, desc, Heap.get_obj(elem(desc, 1), %{}))
        true

      not Heap.extensible?(ref) and not property_present?(existing, prop_name) ->
        false

      is_map(existing) ->
        Heap.put_obj_key(ref, prop_name, value)
        Heap.put_prop_desc(ref, prop_name, PropertyDescriptor.enumerable_data())
        true

      true ->
        desc = data_property_descriptor(value)
        property(obj, prop_name, desc, Heap.get_obj(elem(desc, 1), %{}))
        true
    end
  end

  def create_data_property(_, _key, _value), do: false

  def create_data_property_or_throw(obj, key, value) do
    if create_data_property(obj, key, value) do
      obj
    else
      throw({:js_throw, Heap.make_error("Cannot create property", "TypeError")})
    end
  end

  defp data_property_descriptor(value) do
    Heap.wrap(%{
      "value" => value,
      "writable" => true,
      "enumerable" => true,
      "configurable" => true
    })
  end

  defp property_name(key) do
    case key do
      k when is_binary(k) -> k
      {:symbol, _} -> key
      {:symbol, _, _} -> key
      _ -> Values.stringify(key)
    end
  end

  defp array_prototype_length_property?(raw, "length"),
    do: Semantics.array_prototype_object?(raw)

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

  defp wrapped_string_virtual_incompatible?(map, prop_name, desc) when is_map(map) do
    case WrappedPrimitive.value(map, :string) do
      {:ok, string} when is_binary(string) ->
        wrapped_string_descriptor_incompatible?(string, prop_name, desc)

      _ ->
        false
    end
  end

  defp wrapped_string_virtual_incompatible?(_map, _prop_name, _desc), do: false

  defp wrapped_string_descriptor_incompatible?(string, "length", desc) do
    descriptor_incompatible_with_virtual?(desc, Get.string_length(string), false, false)
  end

  defp wrapped_string_descriptor_incompatible?(string, prop_name, desc) do
    length = Get.string_length(string)

    case PropertyKey.array_index(prop_name) do
      {:ok, index} when index >= 0 and index < length ->
        value = string |> String.graphemes() |> Enum.at(index)
        descriptor_incompatible_with_virtual?(desc, value, false, true)

      _ ->
        false
    end
  end

  defp descriptor_incompatible_with_virtual?(desc, value, writable, enumerable) do
    cond do
      Map.get(desc, "configurable") == true ->
        true

      Map.get(desc, "writable") != nil and Map.get(desc, "writable") != writable ->
        true

      Map.get(desc, "enumerable") != nil and Map.get(desc, "enumerable") != enumerable ->
        true

      Map.has_key?(desc, "value") and not Semantics.same_value?(Map.get(desc, "value"), value) ->
        true

      Map.has_key?(desc, "get") or Map.has_key?(desc, "set") ->
        true

      true ->
        false
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

  defp descriptor_map({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp descriptor_map(_), do: %{}

  def proxy_define_property_invariant_violation?({:obj, target_ref}, prop_name, desc) do
    existing = Heap.get_obj(target_ref, %{})
    current_desc = Heap.get_prop_desc(target_ref, prop_name)

    cond do
      non_extensible_new_property?(target_ref, existing, prop_name) ->
        true

      Map.get(desc, "configurable") == false and
          not match?(%{configurable: false}, current_desc) ->
        true

      incompatible_existing_descriptor?(target_ref, existing, prop_name, desc) ->
        true

      match?(%{configurable: false, writable: true}, current_desc) and
          Map.get(desc, "writable") == false ->
        true

      true ->
        false
    end
  end

  def proxy_define_property_invariant_violation?(_target, _prop_name, _desc), do: false

  defp define_typed_array_index_property(obj, _ref, existing, prop_name, desc) do
    if is_map(existing) and Map.get(existing, typed_array()) do
      case TypedArray.integer_index_key(prop_name) do
        {:ok, idx} ->
          define_typed_array_element!(obj, idx, desc)

        :invalid ->
          throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

        :not_integer_index ->
          :ok
      end
    end
  end

  defp define_typed_array_element!(obj, idx, desc) do
    if TypedArray.out_of_bounds?(obj) or idx >= TypedArray.element_count(obj) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    if Map.has_key?(desc, "get") or Map.has_key?(desc, "set") or
         Map.get(desc, "configurable") == false or Map.get(desc, "enumerable") == false or
         Map.get(desc, "writable") == false do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    if Map.has_key?(desc, "value") do
      TypedArray.set_element(obj, idx, Map.get(desc, "value"))
    end

    throw({:early_return, obj})
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
    raw_key = integer_property_key(prop_name)
    Map.has_key?(map, prop_name) or (raw_key != :error and Map.has_key?(map, raw_key))
  end

  defp property_present?(list, prop_name) when is_list(list) do
    case PropertyKey.array_index(prop_name) do
      {:ok, idx} -> idx < length(list)
      :error -> false
    end
  end

  defp property_present?({:qb_arr, arr}, prop_name) do
    case PropertyKey.array_index(prop_name) do
      {:ok, idx} -> idx < :array.size(arr)
      :error -> false
    end
  end

  defp property_present?(_existing, _prop_name), do: false

  defp integer_property_key(key) do
    case PropertyKey.array_index(key) do
      {:ok, index} -> index
      :error -> :error
    end
  end

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

  defp static_descriptor(callable, "prototype") do
    if Value.has_function_prototype?(callable),
      do: PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: false),
      else: static_descriptor(callable, :not_function_prototype, "prototype")
  end

  defp static_descriptor(callable, prop_name) do
    static_descriptor(callable, :static, prop_name)
  end

  defp static_descriptor(callable, _kind, prop_name) do
    Heap.get_prop_desc(callable, prop_name) || Heap.get_ctor_prop_desc(callable, prop_name)
  end

  defp static_incompatible_descriptor?(callable, existing, prop_name, desc) do
    current_desc = static_descriptor(callable, prop_name)

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

      current_desc.configurable == false and current_desc.writable == false and
        Map.has_key?(desc, "value") and
          not Semantics.same_value?(Map.get(desc, "value"), current_value) ->
        true

      true ->
        false
    end
  end

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
