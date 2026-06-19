defmodule QuickBEAM.VM.ObjectModel.ArrayExotic do
  @moduledoc "Array exotic object semantics for length, integer-indexed properties, and descriptors."

  alias QuickBEAM.VM.{Heap, RuntimeState}
  alias QuickBEAM.VM.Execution.ClosureCells
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.ObjectModel.{PropertyDescriptor, PropertyKey, Put, Semantics}

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
    case PropertyKey.array_index(prop_name) do
      {:ok, idx} ->
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
    length_value = if fields.value_present, do: length_value!(fields.value)

    if fields.getter_present or fields.setter_present or Map.get(desc, "configurable") == true or
         Map.get(desc, "enumerable") == true do
      throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
    end

    current_attrs = length_attrs(ref)

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
      if non_configurable_index_at_or_above?(ref, length_value, current_length(ref)) do
        partially_shrink_to_nonconfigurable!(ref, length_value, current_length(ref), writable)
      end

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
        old_len = current_length(ref)

        if idx >= old_len and match?(%{writable: false}, length_attrs(ref)) do
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

            delete_mapped_argument(ref, idx)
            Heap.put_array_prop(ref, prop_name, {:accessor, new_get, new_set})

          fields.value_present or fields.writable_present or
              (existing_flags == nil and descriptor_attribute_present?(desc)) ->
            value = PropertyDescriptor.field(desc_obj, desc, "value", Heap.array_get(ref, idx))

            unless match?(%{writable: false}, existing_flags) do
              sync_arguments_index(ref, idx, value)
              sync_mapped_argument(ref, idx, value)
            end

            if Map.get(desc, "writable") == false do
              delete_mapped_argument(ref, idx)
            end

            Heap.delete_array_prop(ref, prop_name)
            Heap.array_set(ref, idx, value)

            if value == :undefined do
              Heap.put_array_prop(ref, prop_name, value)
            end

          true ->
            :ok
        end

        if idx >= old_len do
          Put.put(obj, "length", idx + 1)
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
              not Semantics.same_value?(
                Map.get(desc, "value"),
                current_data_value(ref, prop_name)
              ) ->
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

  defp sync_arguments_index(ref, idx, value) do
    if Heap.get_array_prop(ref, "__arguments__") == true and not Semantics.strict_mode?() and
         not deleted_argument?(ref, idx) do
      case RuntimeState.current() do
        %{arg_buf: arg_buf} = ctx when idx < tuple_size(arg_buf) ->
          RuntimeState.install(%{ctx | arg_buf: put_elem(arg_buf, idx, value)})

        _ ->
          :ok
      end
    end
  end

  defp sync_mapped_argument(ref, idx, value) do
    case Heap.get_array_prop(ref, "__mapped_arguments__") do
      mapped when is_map(mapped) ->
        case Map.get(mapped, idx) do
          {:cell, _} = cell -> ClosureCells.write(cell, value)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp deleted_argument?(ref, idx) do
    case Heap.get_array_prop(ref, "__deleted_args__") do
      %MapSet{} = deleted -> MapSet.member?(deleted, idx)
      _ -> false
    end
  end

  defp delete_mapped_argument(ref, idx) do
    case Heap.get_array_prop(ref, "__mapped_arguments__") do
      mapped when is_map(mapped) ->
        Heap.put_array_prop(ref, "__mapped_arguments__", Map.delete(mapped, idx))

      _ ->
        :ok
    end
  end

  defp non_configurable_index_at_or_above?(ref, new_len, old_len),
    do: non_configurable_index(ref, new_len, old_len) != nil

  defp non_configurable_index(ref, new_len, old_len) do
    Enum.find((old_len - 1)..new_len//-1, fn index ->
      match?(%{configurable: false}, Heap.get_prop_desc(ref, Integer.to_string(index)))
    end)
  end

  defp partially_shrink_to_nonconfigurable!(ref, new_len, old_len, writable) do
    kept_len = non_configurable_index(ref, new_len, old_len) + 1

    for index <- kept_len..(old_len - 1)//1 do
      key = Integer.to_string(index)
      Heap.delete_array_prop(ref, key)
      Heap.put_prop_desc(ref, key, nil)
    end

    case Heap.get_obj(ref, []) do
      {:qb_arr, arr} -> Heap.put_obj_raw(ref, {:qb_arr, :array.resize(kept_len, arr)})
      list when is_list(list) -> Heap.put_obj(ref, Enum.take(list, kept_len))
      _ -> Heap.put_array_prop(ref, "length", kept_len)
    end

    if writable == false do
      put_length_attrs(ref, false)
    end

    throw({:js_throw, Heap.make_error("Cannot define property", "TypeError")})
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
    Heap.get_prop_desc(ref, "length") || PropertyDescriptor.fixed_data()
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

  defp descriptor_attrs(desc_obj, desc, existing_attrs, default),
    do: Semantics.descriptor_attrs(desc_obj, desc, existing_attrs, default)

  defp accessor_pair({:accessor, getter, setter}), do: {getter, setter}
  defp accessor_pair(_), do: {nil, nil}
end
