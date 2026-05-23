defmodule QuickBEAM.VM.ObjectModel.ProxyOwnProperty do
  @moduledoc "Proxy [[GetOwnProperty]] dispatch and invariant validation."

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{ProxyDispatch, ProxyTrap}

  def dispatch(proxy_map, prop_name, fallback, target_flags)
      when is_function(fallback, 2) and is_function(target_flags, 2) do
    ProxyDispatch.with_trap(
      proxy_map,
      "getOwnPropertyDescriptor",
      &fallback.(&1, prop_name),
      fn target, handler, trap ->
        validate_result(
          target,
          prop_name,
          ProxyTrap.call(trap, [target, prop_name], handler),
          target_flags
        )
      end
    )
  end

  def validate_result(target, prop_name, :undefined, target_flags)
      when is_function(target_flags, 2) do
    case target_flags.(target, prop_name) do
      %{configurable: false} ->
        invariant_error()

      nil ->
        :undefined

      _flags ->
        if target_extensible?(target), do: :undefined, else: invariant_error()
    end
  end

  def validate_result(target, prop_name, {:obj, result_ref} = result, target_flags)
      when is_function(target_flags, 2) do
    validate_descriptor_object(
      target,
      prop_name,
      Heap.get_obj(result_ref, %{}),
      result,
      target_flags
    )
  end

  def validate_result(target, prop_name, result_desc, target_flags)
      when is_map(result_desc) and is_function(target_flags, 2) do
    validate_descriptor_object(
      target,
      prop_name,
      result_desc,
      Heap.wrap(result_desc),
      target_flags
    )
  end

  def validate_result(_target, _prop_name, _result, _target_flags),
    do: JSThrow.type_error!("proxy getOwnPropertyDescriptor trap returned non-object")

  defp validate_descriptor_object(target, prop_name, result_desc, result, target_flags) do
    cond do
      not target_extensible?(target) and target_flags.(target, prop_name) == nil ->
        invariant_error()

      Map.get(result_desc, "configurable") == false and
          not match?(%{configurable: false}, target_flags.(target, prop_name)) ->
        invariant_error()

      Map.get(result_desc, "configurable") == false and Map.get(result_desc, "writable") == false and
          match?(%{writable: true}, target_flags.(target, prop_name)) ->
        invariant_error()

      true ->
        result
    end
  end

  defp target_extensible?({:obj, ref}), do: Heap.extensible?(ref)
  defp target_extensible?(_target), do: true

  defp invariant_error,
    do: JSThrow.type_error!("proxy getOwnPropertyDescriptor trap violates invariant")
end
