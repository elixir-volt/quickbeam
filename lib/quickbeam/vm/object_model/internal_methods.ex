defmodule QuickBEAM.VM.ObjectModel.InternalMethods do
  @moduledoc "Dispatch facade for ECMAScript object internal methods."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_handler: 0, proxy_target: 0, typed_array: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Value}

  alias QuickBEAM.VM.ObjectModel.{
    Define,
    Delete,
    Get,
    HasProperty,
    OwnProperty,
    ProxyOwnKeys,
    ProxyTrap,
    Put
  }

  alias QuickBEAM.VM.Semantics.Values

  def kind({:obj, ref}) do
    case Heap.get_obj_raw(ref) do
      %{proxy_target() => _target} -> :proxy
      %{typed_array() => true} -> :typed_array
      list when is_list(list) -> :array
      _ -> :ordinary
    end
  end

  def kind(%QuickBEAM.VM.Function{}), do: :function
  def kind({:closure, _, %QuickBEAM.VM.Function{}}), do: :function
  def kind({:builtin, _, _}), do: :function
  def kind({:bound, _, _, _, _}), do: :function
  def kind(_), do: :primitive

  def get(obj, key, receiver \\ nil), do: Get.get(obj, key, receiver || obj)
  def set(obj, key, value, receiver \\ nil)

  def set({:obj, ref} = obj, key, value, receiver) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "set")

        if Value.nullish?(trap) do
          set(target, key, value, receiver || obj)
        else
          trap
          |> ProxyTrap.call([target, key, value, receiver || obj], handler)
          |> then(&Put.validate_proxy_set_invariant(target, key, value, &1))
        end

      _ ->
        Put.ordinary_set(obj, key, value, receiver || obj)
    end
  end

  def set(obj, key, value, receiver), do: Put.ordinary_set(obj, key, value, receiver || obj)

  def has_property({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "has")

        if Value.nullish?(trap) do
          has_property(target, key)
        else
          result = Values.truthy?(ProxyTrap.call(trap, [target, key], handler))
          validate_proxy_has_invariant(target, key, result)
        end

      _ ->
        HasProperty.ordinary_has_property?(obj, key)
    end
  end

  def has_property(obj, key), do: HasProperty.ordinary_has_property?(obj, key)
  def own_property(obj, key), do: OwnProperty.descriptor(obj, key)

  def define_own_property(obj, key, descriptor),
    do: Define.property(obj, key, descriptor, descriptor)

  def delete({:obj, ref} = obj, key) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "deleteProperty")

        if Value.nullish?(trap) do
          delete(target, key)
        else
          result = Values.truthy?(ProxyTrap.call(trap, [target, key], handler))
          validate_proxy_delete_invariant(target, key, result)
        end

      _ ->
        Delete.ordinary_delete_property(obj, key)
    end
  end

  def delete(obj, key), do: Delete.ordinary_delete_property(obj, key)

  def own_keys({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "ownKeys")

        if Value.nullish?(trap) do
          own_keys(target)
        else
          trap
          |> ProxyTrap.call([target], handler)
          |> ProxyOwnKeys.result_list()
          |> ProxyOwnKeys.validate_invariant(target)
        end

      _ ->
        OwnProperty.ordinary_own_keys(obj)
    end
  end

  def own_keys(obj), do: OwnProperty.ordinary_own_keys(obj)

  defp validate_proxy_has_invariant({:obj, target_ref} = target, key, false) do
    desc = Heap.get_prop_desc(target_ref, key)

    cond do
      match?(%{configurable: false}, desc) ->
        JSThrow.type_error!("proxy has trap violates invariant")

      OwnProperty.present?(target, key) and not Heap.extensible?(target_ref) ->
        JSThrow.type_error!("proxy has trap violates invariant")

      true ->
        false
    end
  end

  defp validate_proxy_has_invariant(_target, _key, result), do: result

  defp validate_proxy_delete_invariant({:obj, target_ref}, key, true) do
    case Heap.get_prop_desc(target_ref, key) do
      %{configurable: false} ->
        JSThrow.type_error!("proxy deleteProperty trap violates invariant")

      _ ->
        true
    end
  end

  defp validate_proxy_delete_invariant(_target, _key, result), do: result

  def extensible?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        trap = Get.get(handler, "isExtensible")

        if Value.nullish?(trap) do
          extensible?(target)
        else
          trap_result = Values.truthy?(ProxyTrap.call(trap, [target], handler))
          target_result = extensible?(target)

          if trap_result == target_result do
            trap_result
          else
            JSThrow.type_error!("proxy isExtensible trap violates invariant")
          end
        end

      _ ->
        Heap.extensible?(ref)
    end
  end

  def extensible?(_), do: true
end
