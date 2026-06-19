defmodule QuickBEAM.VM.ObjectModel.ProxyExtensible do
  @moduledoc "Proxy [[IsExtensible]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{ProxyDispatch, ProxyTrap}
  alias QuickBEAM.VM.Semantics.Values

  def dispatch({:obj, ref} = proxy, fallback) when is_function(fallback, 1) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy_map ->
        proxy_fallback = fn target -> dispatch(target, fallback) end

        ProxyDispatch.with_trap(proxy_map, "isExtensible", proxy_fallback, fn target,
                                                                              handler,
                                                                              trap ->
          trap
          |> ProxyTrap.call([target], handler)
          |> Values.truthy?()
          |> validate_invariant(dispatch(target, fallback))
        end)

      _ ->
        fallback.(proxy)
    end
  end

  def dispatch(target, fallback) when is_function(fallback, 1), do: fallback.(target)

  def validate_invariant(trap_result, target_result) do
    if trap_result == target_result do
      trap_result
    else
      JSThrow.type_error!("proxy isExtensible trap violates invariant")
    end
  end
end
