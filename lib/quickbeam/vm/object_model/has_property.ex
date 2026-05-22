defmodule QuickBEAM.VM.ObjectModel.HasProperty do
  @moduledoc "Shared JavaScript [[HasProperty]]-style checks."

  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.ObjectModel.{Get, OwnProperty, PropertyKey, ProxyTrap}
  alias QuickBEAM.VM.Runtime.TypedArray

  def has_property?({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        QuickBEAM.VM.JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => target, proxy_handler() => handler} ->
        has_trap = Get.get(handler, "has")

        if has_trap != :undefined do
          result = Values.truthy?(ProxyTrap.call(has_trap, [target, key], handler))
          validate_proxy_has_invariant(target, key, result)
        else
          has_property?(target, key)
        end

      %{typed_array() => true} = map ->
        case PropertyKey.array_index(key) do
          {:ok, _idx} ->
            if TypedArray.out_of_bounds?(obj),
              do: false,
              else: OwnProperty.present?(obj, key) or prototype_has_property?(obj, map, key)

          _ ->
            OwnProperty.present?(obj, key) or prototype_has_property?(obj, map, key)
        end

      map when is_map(map) ->
        OwnProperty.present?(obj, key) or prototype_has_property?(obj, map, key)

      list when is_list(list) ->
        OwnProperty.present?(obj, key) or has_array_prototype_property?(ref, key)

      {:qb_arr, _} ->
        OwnProperty.present?(obj, key) or has_array_prototype_property?(ref, key)

      _ ->
        Get.get(obj, key) != :undefined
    end
  end

  def has_property?(%QuickBEAM.VM.Function{} = fun, key), do: Get.get(fun, key) != :undefined

  def has_property?({:closure, _, %QuickBEAM.VM.Function{}} = closure, key),
    do: Get.get(closure, key) != :undefined

  def has_property?({:builtin, _, _} = builtin, key), do: Get.get(builtin, key) != :undefined
  def has_property?({:bound, _, _, _, _} = bound, key), do: Get.get(bound, key) != :undefined
  def has_property?({:regexp, _, _, _} = regexp, key), do: Get.get(regexp, key) != :undefined
  def has_property?({:regexp, _, _} = regexp, key), do: Get.get(regexp, key) != :undefined
  def has_property?(map, key) when is_map(map), do: Map.has_key?(map, key)

  def has_property?({:qb_arr, arr}, key) when is_integer(key),
    do: key >= 0 and key < :array.size(arr)

  def has_property?({:qb_arr, arr}, key) when is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < :array.size(arr)
      :error -> false
    end
  end

  def has_property?(list, key) when is_list(list) and is_integer(key),
    do: key >= 0 and key < length(list)

  def has_property?(list, key) when is_list(list) and is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> idx < length(list)
      :error -> false
    end
  end

  def has_property?(_, _), do: false

  defp prototype_has_property?({:obj, ref}, map, key) do
    cond do
      Map.has_key?(map, :__internal_proto__) ->
        has_property?(Map.get(map, :__internal_proto__), key)

      Map.has_key?(map, proto()) ->
        has_property?(Map.get(map, proto()), key)

      object_prototype_ref?(ref) ->
        false

      true ->
        has_property?(Heap.get_object_prototype(), key)
    end
  end

  defp object_prototype_ref?(ref) do
    case Heap.get_object_prototype() do
      {:obj, proto_ref} -> ref == proto_ref
      _ -> false
    end
  end

  defp validate_proxy_has_invariant({:obj, target_ref} = target, key, false) do
    desc = Heap.get_prop_desc(target_ref, key)

    cond do
      match?(%{configurable: false}, desc) ->
        throw({:js_throw, Heap.make_error("proxy has trap violates invariant", "TypeError")})

      OwnProperty.present?(target, key) and not Heap.extensible?(target_ref) ->
        throw({:js_throw, Heap.make_error("proxy has trap violates invariant", "TypeError")})

      true ->
        false
    end
  end

  defp validate_proxy_has_invariant(_target, _key, result), do: result

  defp has_array_prototype_property?(ref, key) do
    has_property?(Heap.get_array_proto(ref), key) or
      has_property?(Heap.get_object_prototype(), key)
  end
end
