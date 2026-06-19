defmodule QuickBEAM.VM.ObjectModel.ProxyPrototype do
  @moduledoc "Proxy [[GetPrototypeOf]] and [[SetPrototypeOf]] dispatch."

  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, ProxyDispatch, ProxyTrap}
  alias QuickBEAM.VM.Semantics.Values

  def get(proxy_map, fallback) when is_function(fallback, 1) do
    proxy_fallback = fn target -> InternalMethods.get_prototype_of(target) end

    ProxyDispatch.with_trap(proxy_map, "getPrototypeOf", proxy_fallback, fn target,
                                                                            handler,
                                                                            trap ->
      trap
      |> ProxyTrap.call([target], handler)
      |> validate_get_result(target)
    end)
  end

  def set(proxy_map, new_proto, fallback) when is_function(fallback, 2) do
    proxy_fallback = fn target -> InternalMethods.set_prototype_of(target, new_proto) end

    ProxyDispatch.with_trap(proxy_map, "setPrototypeOf", proxy_fallback, fn target,
                                                                            handler,
                                                                            trap ->
      trap
      |> ProxyTrap.call([target, new_proto], handler)
      |> Values.truthy?()
      |> validate_set_result(target, new_proto)
    end)
  end

  defp validate_get_result(result, target) do
    cond do
      not prototype_value?(result) ->
        prototype_invariant_error()

      not target_extensible?(target) and result != InternalMethods.get_prototype_of(target) ->
        prototype_invariant_error()

      true ->
        result
    end
  end

  defp validate_set_result(false, _target, _new_proto), do: false

  defp validate_set_result(true, target, new_proto) do
    if not target_extensible?(target) and new_proto != InternalMethods.get_prototype_of(target) do
      prototype_invariant_error()
    end

    true
  end

  defp prototype_value?(nil), do: true
  defp prototype_value?({:obj, _}), do: true
  defp prototype_value?(_), do: false

  defp target_extensible?(target), do: InternalMethods.extensible?(target)

  defp prototype_invariant_error,
    do: JSThrow.type_error!("proxy prototype trap violates invariant")
end
