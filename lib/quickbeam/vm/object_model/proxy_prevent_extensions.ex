defmodule QuickBEAM.VM.ObjectModel.ProxyPreventExtensions do
  @moduledoc "Proxy [[PreventExtensions]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{ProxyDispatch, ProxyTrap}
  alias QuickBEAM.VM.Semantics.Values

  def dispatch({:obj, ref} = proxy, fallback) when is_function(fallback, 1) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy_map ->
        proxy_fallback = fn target -> dispatch(target, fallback) end

        ProxyDispatch.with_trap(proxy_map, "preventExtensions", proxy_fallback, fn target,
                                                                                   handler,
                                                                                   trap ->
          trap_result = ProxyTrap.call(trap, [target], handler) |> Values.truthy?()

          cond do
            not trap_result ->
              false

            extensible?(target) ->
              JSThrow.type_error!("proxy preventExtensions trap violates invariant")

            true ->
              true
          end
        end)

      _ ->
        fallback.(proxy)
    end
  end

  def dispatch(target, fallback) when is_function(fallback, 1), do: fallback.(target)

  defp extensible?({:obj, ref}), do: Heap.extensible?(ref)
  defp extensible?(_), do: true
end
