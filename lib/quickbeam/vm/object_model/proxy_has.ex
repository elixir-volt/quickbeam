defmodule QuickBEAM.VM.ObjectModel.ProxyHas do
  @moduledoc "Proxy [[HasProperty]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, ProxyDispatch, ProxyTrap}
  alias QuickBEAM.VM.Semantics.Values

  def dispatch({:obj, ref} = proxy, key, fallback) when is_function(fallback, 2) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy_map ->
        proxy_fallback = fn target -> dispatch(target, key, fallback) end

        ProxyDispatch.with_trap(proxy_map, "has", proxy_fallback, fn target, handler, trap ->
          trap_result = trap |> ProxyTrap.call([target, key], handler) |> Values.truthy?()
          validate_invariant(target, key, trap_result)
        end)

      _ ->
        fallback.(proxy, key)
    end
  end

  def dispatch(target, key, fallback) when is_function(fallback, 2),
    do: fallback.(target, key)

  def validate_invariant({:obj, target_ref} = target, key, false) do
    desc = Heap.get_prop_desc(target_ref, key)

    cond do
      match?(%{configurable: false}, desc) ->
        JSThrow.type_error!("proxy has trap violates invariant")

      InternalMethods.own_property_present?(target, key) and
          not InternalMethods.extensible?(target) ->
        JSThrow.type_error!("proxy has trap violates invariant")

      true ->
        false
    end
  end

  def validate_invariant(_target, _key, result), do: result
end
