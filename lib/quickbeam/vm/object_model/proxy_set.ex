defmodule QuickBEAM.VM.ObjectModel.ProxySet do
  @moduledoc "Proxy [[Set]] dispatch and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{ProxyDispatch, ProxyTrap, Semantics}
  alias QuickBEAM.VM.Semantics.Values

  def dispatch({:obj, ref} = proxy, key, value, receiver, fallback)
      when is_function(fallback, 4) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy_map ->
        receiver = receiver || proxy

        ProxyDispatch.with_trap(proxy_map, "set", &fallback.(&1, key, value, receiver), fn target,
                                                                                           handler,
                                                                                           trap ->
          trap_result = ProxyTrap.call(trap, [target, key, value, receiver], handler)
          validate_invariant(target, key, value, trap_result)
        end)

      _ ->
        fallback.(proxy, key, value, receiver || proxy)
    end
  end

  def dispatch(target, key, value, receiver, fallback) when is_function(fallback, 4),
    do: fallback.(target, key, value, receiver || target)

  def validate_invariant({:obj, target_ref}, key, value, trap_result) do
    if Values.truthy?(trap_result) do
      desc = Heap.get_prop_desc(target_ref, key)

      cond do
        match?(%{configurable: false, writable: false}, desc) and
          data_property?(target_ref, key) and
            not Semantics.same_value?(value, raw_target_value(target_ref, key)) ->
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

  defp data_property?(target_ref, key) do
    case Heap.raw_fetch(Heap.get_obj_raw(target_ref), key) do
      {:ok, {:accessor, _, _}} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  defp raw_target_value(target_ref, key) do
    case Heap.raw_fetch(Heap.get_obj_raw(target_ref), key) do
      {:ok, value} -> value
      :error -> :undefined
    end
  end

  defp getter_only_accessor?(target_ref, key) do
    case Heap.raw_fetch(Heap.get_obj_raw(target_ref), key) do
      {:ok, {:accessor, _, nil}} -> true
      _ -> false
    end
  end
end
