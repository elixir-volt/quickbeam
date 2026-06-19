defmodule QuickBEAM.VM.ObjectModel.Delete do
  @moduledoc "Implements JavaScript [[Delete]] semantics for VM values."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.Semantics.Values

  alias QuickBEAM.VM.ObjectModel.{
    InternalMethods,
    PropertyKey,
    Semantics,
    Static,
    WrappedPrimitive
  }

  @doc "Deletes a property according to JavaScript delete semantics."
  def delete_property(target, key), do: InternalMethods.delete(target, key)

  def ordinary_delete_property(nil, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot delete properties of null (deleting '#{key_label(key)}')",
         "TypeError"
       )}
    )
  end

  def ordinary_delete_property(:undefined, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot delete properties of undefined (deleting '#{key_label(key)}')",
         "TypeError"
       )}
    )
  end

  def ordinary_delete_property({:obj, ref}, "length" = key) do
    if array_prototype_object?(Heap.get_obj_raw(ref)) do
      false
    else
      delete_object_property({:obj, ref}, key)
    end
  end

  def ordinary_delete_property({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} -> delete_typed_array_property(obj, key)
      _ -> delete_object_property(obj, key)
    end
  end

  def ordinary_delete_property({:builtin, _name, _} = builtin, key) do
    delete_static_property(builtin, key)
  end

  def ordinary_delete_property({:regexp, _, _, ref}, key) do
    if key == "lastIndex" or match?(%{configurable: false}, Heap.get_prop_desc(ref, key)) do
      false
    else
      RegexpState.delete(ref, key)
      Heap.delete_prop_desc(ref, key)
      true
    end
  end

  def ordinary_delete_property(target, key) when is_tuple(target) or is_struct(target) do
    delete_static_property(target, key)
  end

  def ordinary_delete_property(_obj, _key), do: true

  defp delete_typed_array_property(obj, key) do
    case QuickBEAM.VM.Runtime.TypedArray.integer_index_key(key) do
      {:ok, idx} ->
        not (idx < QuickBEAM.VM.Runtime.TypedArray.element_count(obj))

      :invalid ->
        true

      :not_integer_index ->
        delete_object_property(obj, key)
    end
  end

  defp delete_object_property({:obj, ref}, key) do
    key = PropertyKey.normalize(key)

    if key in ["caller", "arguments"] and Heap.get_func_proto() == {:obj, ref} do
      Heap.put_prop_desc(ref, key, :deleted)
      true
    else
      case Heap.get_obj(ref, %{}) do
        map when is_map(map) ->
          desc = Heap.get_prop_desc(ref, key)

          if wrapped_string_virtual_non_configurable?(map, key) or
               match?(%{configurable: false}, desc) do
            false
          else
            updated =
              map
              |> delete_ordinary_key(key)
              |> remove_key_order_entry(key)

            Heap.put_obj(ref, updated)
            mark_wrapped_virtual_delete(ref, map, key)
            mark_regexp_prototype_delete(ref, key)
            mark_date_prototype_delete(ref, key)
            true
          end

        {:qb_arr, _} ->
          delete_array_property(ref, key)

        list when is_list(list) ->
          delete_array_property(ref, key)

        _ ->
          true
      end
    end
  end

  defp array_prototype_object?(raw), do: Semantics.array_prototype_object?(raw)

  defp wrapped_string_virtual_non_configurable?(map, "length") do
    match?({:ok, string} when is_binary(string), WrappedPrimitive.value(map, :string))
  end

  defp wrapped_string_virtual_non_configurable?(map, key) when is_map(map) do
    with {:ok, string} when is_binary(string) <- WrappedPrimitive.value(map, :string),
         {:ok, index} <- PropertyKey.array_index(key) do
      index >= 0 and index < QuickBEAM.VM.ObjectModel.Get.string_length(string)
    else
      _ -> false
    end
  end

  defp wrapped_string_virtual_non_configurable?(_map, _key), do: false

  defp mark_wrapped_virtual_delete(ref, map, key) when is_binary(key) do
    if WrappedPrimitive.any_type?(map) and
         key in ~w(toString valueOf toFixed toExponential toPrecision toLocaleString) do
      Heap.put_prop_desc(ref, key, :deleted)
    end
  end

  defp mark_wrapped_virtual_delete(_ref, _map, _key), do: :ok

  defp mark_regexp_prototype_delete(ref, key) do
    if QuickBEAM.VM.Runtime.global_class_proto("RegExp") == {:obj, ref} and
         key in [{:symbol, "Symbol.match"}, {:symbol, "Symbol.matchAll"}] do
      if key == {:symbol, "Symbol.matchAll"},
        do: QuickBEAM.VM.Execution.RegexpState.delete_match_all_override()

      Heap.put_prop_desc(ref, key, :deleted)
    end
  end

  defp mark_date_prototype_delete(ref, key) do
    if QuickBEAM.VM.Runtime.global_class_proto("Date") == {:obj, ref} and
         QuickBEAM.VM.Runtime.Date.proto_property(key) != :undefined do
      Heap.put_prop_desc(ref, key, :deleted)
    end
  end

  defp delete_ordinary_key(map, key) when is_integer(key) and key >= 0 do
    map |> Map.delete(key) |> Map.delete(Integer.to_string(key))
  end

  defp delete_ordinary_key(map, key) do
    case PropertyKey.array_index(key) do
      :error -> Map.delete(map, key)
      {:ok, index} -> map |> Map.delete(key) |> Map.delete(index)
    end
  end

  defp remove_key_order_entry(map, key) when is_binary(key) or is_integer(key) do
    case Map.get(map, key_order()) do
      order when is_list(order) -> Map.put(map, key_order(), List.delete(order, key))
      _ -> map
    end
  end

  defp remove_key_order_entry(map, _key), do: map

  defp delete_static_property(target, key) do
    if non_configurable_static_prototype?(target, key) or
         match?(
           %{configurable: false},
           Heap.get_prop_desc(target, key) || Heap.get_ctor_prop_desc(target, key)
         ) do
      false
    else
      Static.delete_static(target, key)
    end
  end

  defp non_configurable_static_prototype?(target, "prototype"),
    do:
      Value.has_function_prototype?(target) or
        Map.has_key?(Heap.get_ctor_statics(target), "prototype")

  defp non_configurable_static_prototype?(_target, _key), do: false

  defp visible_array_length(ref) do
    case Heap.get_array_prop(ref, "length") do
      len when is_integer(len) ->
        len

      _ ->
        case Heap.get_obj_raw(ref) do
          {:qb_arr, arr} -> :array.size(arr)
          list when is_list(list) -> length(list)
          _ -> 0
        end
    end
  end

  defp delete_array_property(_ref, "length"), do: false

  defp delete_array_property(ref, key) do
    key = PropertyKey.normalize(key)

    case PropertyKey.array_index(key) do
      {:ok, idx} ->
        if match?(%{configurable: false}, Heap.get_prop_desc(ref, key)) do
          false
        else
          if Heap.get_array_prop(ref, "__arguments__") == true do
            deleted = Heap.get_array_prop(ref, "__deleted_args__")
            deleted = if match?(%MapSet{}, deleted), do: deleted, else: MapSet.new()
            Heap.put_array_prop(ref, "__deleted_args__", MapSet.put(deleted, idx))
            delete_mapped_argument(ref, idx)
          end

          unless idx >= visible_array_length(ref) do
            Heap.array_set(ref, idx, :undefined)
          end

          Heap.delete_prop_desc(ref, key)
          Heap.delete_array_prop(ref, key)
          true
        end

      _ ->
        if match?(%{configurable: false}, Heap.get_prop_desc(ref, key)) do
          false
        else
          Heap.delete_array_prop(ref, key)
          Heap.delete_prop_desc(ref, key)
          true
        end
    end
  end

  defp key_label({:symbol, _, _} = key), do: Value.symbol_name(key)
  defp key_label({:symbol, _} = key), do: Value.symbol_name(key)
  defp key_label(key), do: Values.stringify(key)

  defp delete_mapped_argument(ref, idx) do
    case Heap.get_array_prop(ref, "__mapped_arguments__") do
      mapped when is_map(mapped) ->
        Heap.put_array_prop(ref, "__mapped_arguments__", Map.delete(mapped, idx))

      _ ->
        :ok
    end
  end
end
