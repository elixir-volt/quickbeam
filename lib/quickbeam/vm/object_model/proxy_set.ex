defmodule QuickBEAM.VM.ObjectModel.ProxySet do
  @moduledoc "Proxy [[Set]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_handler: 0, proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Value}
  alias QuickBEAM.VM.ObjectModel.{Get, ProxyTrap, Semantics}
  alias QuickBEAM.VM.Semantics.Values

  def dispatch({:obj, ref} = proxy, key, value, receiver, fallback)
      when is_function(fallback, 4) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target, "__proxy_revoked__" => true} ->
        JSThrow.type_error!("Cannot perform operation on a revoked proxy")

      %{proxy_target() => _target, proxy_handler() => handler}
      when not is_map(handler) and not is_tuple(handler) ->
        JSThrow.type_error!("Cannot perform operation on a proxy with null handler")

      %{proxy_target() => target, proxy_handler() => handler} ->
        set_trap(target, handler, key, value, receiver || proxy, fallback)

      _ ->
        fallback.(proxy, key, value, receiver || proxy)
    end
  end

  def dispatch(target, key, value, receiver, fallback) when is_function(fallback, 4),
    do: fallback.(target, key, value, receiver || target)

  def validate_invariant({:obj, target_ref} = target, key, value, trap_result) do
    if Values.truthy?(trap_result) do
      desc = Heap.get_prop_desc(target_ref, key)
      target_value = Get.get(target, key)

      cond do
        match?(%{configurable: false, writable: false}, desc) and
            not Semantics.same_value?(value, target_value) ->
          JSThrow.type_error!("proxy set trap violates invariant")

        match?(%{configurable: false}, desc) and getter_only_accessor?(target_ref, key) ->
          JSThrow.type_error!("proxy set trap violates invariant")

        true ->
          trap_result
      end
    else
      trap_result
    end
  end

  def validate_invariant(_target, _key, _value, trap_result), do: trap_result

  defp set_trap(target, handler, key, value, receiver, fallback) do
    trap = Get.get(handler, "set")

    if Value.nullish?(trap) do
      fallback.(target, key, value, receiver)
    else
      trap
      |> ProxyTrap.call([target, key, value, receiver], handler)
      |> validate_invariant(target, key, value)
    end
  end

  defp getter_only_accessor?(target_ref, key) do
    case Heap.raw_fetch(Heap.get_obj_raw(target_ref), key) do
      {:ok, {:accessor, _, nil}} -> true
      _ -> false
    end
  end
end
