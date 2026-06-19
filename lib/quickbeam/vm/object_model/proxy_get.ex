defmodule QuickBEAM.VM.ObjectModel.ProxyGet do
  @moduledoc "Proxy [[Get]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{ProxyDispatch, ProxyTrap, Semantics}

  def dispatch(proxy_map, target, _handler, key, receiver, fallback, target_slot)
      when is_function(fallback, 3) and is_function(target_slot, 2) do
    target_proxy_was_live = live_proxy?(target)

    try do
      ProxyDispatch.with_trap(proxy_map, "get", &fallback.(&1, key, receiver), fn target,
                                                                                  handler,
                                                                                  trap ->
        trap_result = ProxyTrap.call(trap, [target, key, receiver], handler)
        validate_invariant(target, key, trap_result, target_slot)
      end)
    catch
      {:js_throw, error} ->
        if target_proxy_was_live and revoked_proxy_error?(error) do
          :undefined
        else
          throw({:js_throw, error})
        end
    end
  end

  defp revoked_proxy_error?(%{name: "TypeError", message: message}) when is_binary(message),
    do: String.contains?(message, "revoked proxy")

  defp revoked_proxy_error?({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"name" => "TypeError", "message" => message} when is_binary(message) ->
        String.contains?(message, "revoked proxy")

      _ ->
        false
    end
  end

  defp revoked_proxy_error?(_), do: false

  defp live_proxy?({:obj, ref}) do
    case Heap.get_obj_raw(ref) do
      proxy when is_map(proxy) ->
        Map.has_key?(proxy, proxy_target()) and Map.has_key?(proxy, proxy_handler()) and
          Map.get(proxy, "__proxy_revoked__") != true

      _ ->
        false
    end
  end

  defp live_proxy?(_), do: false

  def validate_invariant(target, key, trap_result, target_slot)
      when is_function(target_slot, 2) do
    case target do
      {:obj, target_ref} -> validate_object_invariant(target_ref, key, trap_result, target_slot)
      _ -> trap_result
    end
  end

  defp validate_object_invariant(target_ref, key, trap_result, target_slot) do
    desc = Heap.get_prop_desc(target_ref, key)
    target_value = target_slot.({:obj, target_ref}, key)

    cond do
      match?(%{configurable: false, writable: false}, desc) and
        not match?({:accessor, _, _}, target_value) and
          not Semantics.same_value?(trap_result, target_value) ->
        JSThrow.type_error!("proxy get trap violates invariant")

      match?(%{configurable: false}, desc) and match?({:accessor, nil, _}, target_value) and
          trap_result != :undefined ->
        JSThrow.type_error!("proxy get trap violates invariant")

      true ->
        trap_result
    end
  end
end
