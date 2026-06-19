defmodule QuickBEAM.VM.ObjectModel.ProxyDefine do
  @moduledoc "Proxy [[DefineOwnProperty]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{ProxyDispatch, ProxyTrap}
  alias QuickBEAM.VM.Semantics.Values

  def dispatch({:obj, ref} = proxy, key, prop_name, desc_obj, fallback, invariant?)
      when is_function(fallback, 3) and is_function(invariant?, 3) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy_map ->
        ProxyDispatch.with_trap(
          proxy_map,
          "defineProperty",
          fn target ->
            fallback.(target, key, desc_obj)
            proxy
          end,
          fn target, handler, trap ->
            validate_trap_result(
              proxy,
              target,
              prop_name,
              desc_obj,
              ProxyTrap.call(trap, [target, prop_name, desc_obj], handler),
              invariant?
            )
          end
        )

      _ ->
        fallback.(proxy, key, desc_obj)
    end
  end

  def dispatch(target, key, _prop_name, desc_obj, fallback, _invariant?)
      when is_function(fallback, 3),
      do: fallback.(target, key, desc_obj)

  defp validate_trap_result(proxy, target, prop_name, desc_obj, trap_result, invariant?) do
    cond do
      not Values.truthy?(trap_result) ->
        JSThrow.type_error!("proxy defineProperty trap returned false")

      invariant?.(target, prop_name, descriptor_map(desc_obj)) ->
        JSThrow.type_error!("proxy defineProperty trap violates invariant")

      true ->
        proxy
    end
  end

  defp descriptor_map({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp descriptor_map(_), do: %{}
end
