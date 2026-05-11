defmodule QuickBEAM.VM.ObjectModel.ArrayExotic do
  @moduledoc "Array exotic object semantics for length, integer-indexed properties, and descriptors."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{PropertyDescriptor, PropertyKey, Put}

  def define_own_property(obj, ref, existing, prop_name, desc_obj, desc, fields) do
    cond do
      array?(existing) and prop_name == "length" ->
        define_length_property!(obj, ref, desc_obj, desc, fields)

      array?(existing) ->
        define_index_or_named_property(obj, ref, prop_name, desc_obj, desc, fields)

      true ->
        :not_array
    end
  end

  def descriptor(ref, data, "length") do
    attrs =
      Heap.get_prop_desc(ref, "length") ||
        PropertyDescriptor.attrs(writable: true, enumerable: false, configurable: false)

    PropertyDescriptor.data_object(current_length(ref, data), attrs)
  end

  def descriptor(ref, _data, prop_name) do
    case Integer.parse(prop_name) do
      {idx, ""} when idx >= 0 ->
        case Heap.get_array_prop(ref, prop_name) do
          {:accessor, getter, setter} ->
            PropertyDescriptor.accessor_object(getter, setter, descriptor_attrs(ref, prop_name))

          _ ->
            val = Heap.array_get(ref, idx)

            if val == :undefined and Heap.get_prop_desc(ref, prop_name) == nil do
              :undefined
            else
              data_desc =
                Heap.get_prop_desc(ref, prop_name) ||
                  PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)

              PropertyDescriptor.data_object(val, data_desc)
            end
        end

      _ ->
        case Heap.get_array_prop(ref, prop_name) do
          {:accessor, getter, setter} ->
            PropertyDescriptor.accessor_object(getter, setter, descriptor_attrs(ref, prop_name))

          :undefined ->
            if Heap.get_prop_desc(ref, prop_name) do
              PropertyDescriptor.data_object(:undefined, descriptor_attrs(ref, prop_name))
            else
              :undefined
            end

          val ->
            PropertyDescriptor.data_object(val, descriptor_attrs(ref, prop_name))
        end
    end
  end

  defp descriptor_attrs(ref, prop_name) do
    Heap.get_prop_desc(ref, prop_name) ||
      PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)
  end

  def array_length({:qb_arr, arr}), do: :array.size(arr)
  def array_length(list) when is_list(list), do: length(list)

  def array?(existing), do: is_list(existing) or match?({:qb_arr, _}, existing)

  defp define_length_property!(obj, ref, desc_obj, desc, fields) do
    if fields.getter_present or fields.setter_present or Map.get(desc, "configurable") == true or
         Map.get(desc, "enumerable") == true do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    current_attrs = length_attrs(ref)

    length_value = if fields.value_present, do: length_value!(fields.value)

    if current_attrs.writable == false and
         (Map.get(desc, "writable") == true or
            (fields.value_present and length_value != current_length(ref))) do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    writable =
      if fields.writable_present,
        do:
          Values.truthy?(
            PropertyDescriptor.field(desc_obj, desc, "writable", current_attrs.writable)
          ),
        else: current_attrs.writable

    if fields.value_present and length_value != current_length(ref) do
      try do
        Put.put(obj, "length", length_value)
      catch
        {:js_throw, _} = thrown ->
          if writable == false do
            put_length_attrs(ref, false)
          end

          throw(thrown)
      end
    end

    put_length_attrs(ref, writable)

    obj
  end

  defp define_index_or_named_property(obj, ref, prop_name, desc_obj, desc, fields) do
    reject_incompatible_descriptor!(ref, prop_name, desc)

    case PropertyKey.array_index(prop_name) do
      {:ok, idx} ->
        if idx >= current_length(ref) and match?(%{writable: false}, length_attrs(ref)) do
          throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
        end

        existing_flags = existing_index_attrs(ref, idx, prop_name)

        Heap.put_prop_desc(
          ref,
          prop_name,
          descriptor_attrs(desc_obj, desc, existing_flags, false)
        )

        cond do
          fields.getter_present or fields.setter_present ->
            existing_desc = Heap.get_array_prop(ref, prop_name)
            {old_get, old_set} = accessor_pair(existing_desc)

            new_get =
              PropertyDescriptor.accessor_slot(fields.getter_present, fields.getter, old_get)

            new_set =
              PropertyDescriptor.accessor_slot(fields.setter_present, fields.setter, old_set)

            Heap.put_array_prop(ref, prop_name, {:accessor, new_get, new_set})

          fields.value_present or fields.writable_present or
              (existing_flags == nil and descriptor_attribute_present?(desc)) ->
            value = PropertyDescriptor.field(desc_obj, desc, "value", Heap.array_get(ref, idx))

            unless match?(%{writable: false}, existing_flags) do
              sync_arguments_index(ref, idx, value)
            end

            Heap.delete_array_prop(ref, prop_name)
            Heap.array_set(ref, idx, value)

            if value == :undefined do
              Heap.put_array_prop(ref, prop_name, value)
            end

          true ->
            :ok
        end

        obj

      :error ->
        define_named_property(ref, prop_name, desc_obj, desc, fields)
        obj
    end
  end

  defp define_named_property(ref, prop_name, desc_obj, desc, fields) do
    if fields.getter_present or fields.setter_present do
      existing_desc = Heap.get_array_prop(ref, prop_name)
      {old_get, old_set} = accessor_pair(existing_desc)
      new_get = PropertyDescriptor.accessor_slot(fields.getter_present, fields.getter, old_get)
      new_set = PropertyDescriptor.accessor_slot(fields.setter_present, fields.setter, old_set)
      Heap.put_array_prop(ref, prop_name, {:accessor, new_get, new_set})
    else
      val = PropertyDescriptor.field(desc_obj, desc, "value", Heap.get_array_prop(ref, prop_name))
      Heap.put_array_prop(ref, prop_name, val)
    end

    existing_flags = Heap.get_prop_desc(ref, prop_name)
    Heap.put_prop_desc(ref, prop_name, descriptor_attrs(desc_obj, desc, existing_flags, false))
  end

  defp reject_incompatible_descriptor!(ref, prop_name, desc) do
    case Heap.get_prop_desc(ref, prop_name) do
      %{configurable: false} = current ->
        cond do
          Map.get(desc, "configurable") == true ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          Map.has_key?(desc, "enumerable") and Map.get(desc, "enumerable") != current.enumerable ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          descriptor_kind_conflict?(ref, prop_name, desc) or
              accessor_slot_conflict?(ref, prop_name, desc) ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          current.writable == false and Map.get(desc, "writable") == true ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          current.writable == false and Map.has_key?(desc, "value") and
              not same_value?(Map.get(desc, "value"), current_data_value(ref, prop_name)) ->
            throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp current_data_value(ref, prop_name) do
    case PropertyKey.array_index(prop_name) do
      {:ok, idx} -> Heap.array_get(ref, idx)
      :error -> Heap.get_array_prop(ref, prop_name)
    end
  end

  defp same_value?(a, b) when is_number(a) and is_number(b) and a == 0 and b == 0,
    do: Values.neg_zero?(a) == Values.neg_zero?(b)

  defp same_value?(a, b) when is_number(a) and is_number(b), do: a === b
  defp same_value?(:nan, :nan), do: true
  defp same_value?(a, b), do: a === b

  defp sync_arguments_index(ref, idx, value) do
    if Heap.get_array_prop(ref, "__arguments__") == true and not strict_mode?() and
         not deleted_argument?(ref, idx) do
      case Heap.get_ctx() do
        %{arg_buf: arg_buf} = ctx when idx < tuple_size(arg_buf) ->
          Heap.put_ctx(%{ctx | arg_buf: put_elem(arg_buf, idx, value)})

        _ ->
          :ok
      end
    end
  end

  defp deleted_argument?(ref, idx) do
    case Heap.get_array_prop(ref, "__deleted_args__") do
      %MapSet{} = deleted -> MapSet.member?(deleted, idx)
      _ -> false
    end
  end

  defp strict_mode? do
    case Heap.get_ctx() do
      %{current_func: {:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}} -> true
      %{current_func: %QuickBEAM.VM.Function{is_strict_mode: true}} -> true
      _ -> false
    end
  end

  defp descriptor_attribute_present?(desc) do
    Map.has_key?(desc, "writable") or Map.has_key?(desc, "enumerable") or
      Map.has_key?(desc, "configurable")
  end

  defp existing_index_attrs(ref, idx, prop_name) do
    Heap.get_prop_desc(ref, prop_name) ||
      if Heap.array_get(ref, idx) != :undefined or
           Heap.get_array_prop(ref, prop_name) != :undefined or
           idx < current_length(ref) do
        PropertyDescriptor.attrs(writable: true, enumerable: true, configurable: true)
      end
  end

  defp descriptor_kind_conflict?(ref, prop_name, desc) do
    current_accessor? = match?({:accessor, _, _}, Heap.get_array_prop(ref, prop_name))
    new_accessor? = Map.has_key?(desc, "get") or Map.has_key?(desc, "set")
    new_data? = Map.has_key?(desc, "value") or Map.has_key?(desc, "writable")

    (current_accessor? and new_data?) or (not current_accessor? and new_accessor?)
  end

  defp accessor_slot_conflict?(ref, prop_name, desc) do
    case Heap.get_array_prop(ref, prop_name) do
      {:accessor, getter, setter} ->
        (Map.has_key?(desc, "get") and normalize_accessor(Map.get(desc, "get")) != getter) or
          (Map.has_key?(desc, "set") and normalize_accessor(Map.get(desc, "set")) != setter)

      _ ->
        false
    end
  end

  defp normalize_accessor(:undefined), do: nil
  defp normalize_accessor(value), do: value

  defp length_attrs(ref) do
    Heap.get_prop_desc(ref, "length") ||
      %{writable: true, enumerable: false, configurable: false}
  end

  defp put_length_attrs(ref, writable) do
    Heap.put_prop_desc(ref, "length", %{
      writable: writable,
      enumerable: false,
      configurable: false
    })
  end

  defp current_length(ref), do: current_length(ref, nil)

  defp current_length(ref, data) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) -> len
      _ when data != nil -> array_length(data)
      _ -> Heap.array_size(ref)
    end
  end

  defp length_value!(value) do
    number = Values.to_number(value)
    length = Values.to_uint32(value)

    cond do
      not is_number(number) ->
        throw({:js_throw, Heap.make_error("Invalid array length", "RangeError")})

      number != length ->
        throw({:js_throw, Heap.make_error("Invalid array length", "RangeError")})

      true ->
        length
    end
  end

  defp descriptor_attrs(desc_obj, desc, existing_attrs, default) do
    PropertyDescriptor.attrs(
      writable: PropertyDescriptor.attribute(desc_obj, desc, "writable", existing_attrs, default),
      enumerable:
        PropertyDescriptor.attribute(desc_obj, desc, "enumerable", existing_attrs, default),
      configurable:
        PropertyDescriptor.attribute(desc_obj, desc, "configurable", existing_attrs, default)
    )
  end

  defp accessor_pair({:accessor, getter, setter}), do: {getter, setter}
  defp accessor_pair(_), do: {nil, nil}
end
