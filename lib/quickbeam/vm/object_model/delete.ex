defmodule QuickBEAM.VM.ObjectModel.Delete do
  @moduledoc "Implements JavaScript [[Delete]] semantics for VM values."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Invocation
  alias QuickBEAM.VM.ObjectModel.{Get, Semantics, WrappedPrimitive}

  @doc "Deletes a property according to JavaScript delete semantics."
  def delete_property(nil, key) do
    throw(
      {:js_throw,
       Heap.make_error("Cannot delete properties of null (deleting '#{key}')", "TypeError")}
    )
  end

  def delete_property(:undefined, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot delete properties of undefined (deleting '#{key}')",
         "TypeError"
       )}
    )
  end

  def delete_property({:obj, ref}, key) do
    if key in ["caller", "arguments"] and Heap.get_func_proto() == {:obj, ref} do
      Heap.put_prop_desc(ref, key, :deleted)
      true
    else
      case Heap.get_obj(ref, %{}) do
        %{proxy_target() => target, proxy_handler() => handler} ->
          delete_proxy_property(target, handler, key)

        map when is_map(map) ->
          desc = Heap.get_prop_desc(ref, key)

          if match?(%{configurable: false}, desc) do
            false
          else
            updated =
              map
              |> delete_ordinary_key(key)
              |> remove_key_order_entry(key)

            Heap.put_obj(ref, updated)
            mark_wrapped_virtual_delete(ref, map, key)
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

  def delete_property({:builtin, _name, _} = builtin, key) do
    delete_static_property(builtin, key)
  end

  def delete_property(target, key) when is_tuple(target) or is_struct(target) do
    delete_static_property(target, key)
  end

  def delete_property(_obj, _key), do: true

  defp mark_wrapped_virtual_delete(ref, map, key) when is_binary(key) do
    if WrappedPrimitive.type(map) != nil and
         key in ~w(toString valueOf toFixed toExponential toPrecision toLocaleString) do
      Heap.put_prop_desc(ref, key, :deleted)
    end
  end

  defp mark_wrapped_virtual_delete(_ref, _map, _key), do: :ok

  defp delete_ordinary_key(map, key) when is_integer(key) and key >= 0 do
    map |> Map.delete(key) |> Map.delete(Integer.to_string(key))
  end

  defp delete_ordinary_key(map, key) do
    case Semantics.parse_array_index_key(key) do
      :error -> Map.delete(map, key)
      index -> map |> Map.delete(key) |> Map.delete(index)
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
    if match?(
         %{configurable: false},
         Heap.get_prop_desc(target, key) || Heap.get_ctor_prop_desc(target, key)
       ) do
      false
    else
      Heap.put_ctor_static(target, key, :deleted)
      true
    end
  end

  defp delete_proxy_property(target, handler, key) do
    trap = Get.get(handler, "deleteProperty")

    cond do
      trap == :undefined or trap == nil ->
        delete_property(target, key)

      not Values.truthy?(Invocation.invoke_callback_or_throw(trap, [target, key])) ->
        false

      proxy_delete_invariant_violation?(target, key) ->
        throw(
          {:js_throw,
           Heap.make_error("proxy deleteProperty trap violates invariant", "TypeError")}
        )

      true ->
        true
    end
  end

  defp proxy_delete_invariant_violation?({:obj, ref}, key) do
    match?(%{configurable: false}, Heap.get_prop_desc(ref, key))
  end

  defp proxy_delete_invariant_violation?(_target, _key), do: false

  defp delete_array_property(_ref, "length"), do: false

  defp delete_array_property(ref, key) do
    key = if is_binary(key), do: key, else: Values.stringify(key)

    case Integer.parse(key) do
      {idx, ""} when idx >= 0 ->
        if match?(%{configurable: false}, Heap.get_prop_desc(ref, key)) do
          false
        else
          if Heap.get_array_prop(ref, "__arguments__") == true do
            deleted = Heap.get_array_prop(ref, "__deleted_args__")
            deleted = if match?(%MapSet{}, deleted), do: deleted, else: MapSet.new()
            Heap.put_array_prop(ref, "__deleted_args__", MapSet.put(deleted, idx))
          end

          Heap.array_set(ref, idx, :undefined)
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
end
