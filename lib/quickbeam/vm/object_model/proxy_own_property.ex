defmodule QuickBEAM.VM.ObjectModel.ProxyOwnProperty do
  @moduledoc "Proxy [[GetOwnProperty]] dispatch and invariant validation."

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, ProxyDispatch, ProxyTrap, Semantics}

  def dispatch(proxy_map, prop_name, fallback, target_flags)
      when is_function(fallback, 2) and is_function(target_flags, 2) do
    ProxyDispatch.with_trap(
      proxy_map,
      "getOwnPropertyDescriptor",
      fn target -> dispatch_fallback(target, prop_name, fallback) end,
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
    target_flags = target_flags.(target, prop_name)
    target_desc = target_descriptor(target, prop_name)

    cond do
      not target_extensible?(target) and target_flags == nil ->
        invariant_error()

      Map.get(result_desc, "configurable") == false and
          not match?(%{configurable: false}, target_flags) ->
        invariant_error()

      Map.get(result_desc, "configurable") == false and Map.get(result_desc, "writable") == false and
          match?(%{writable: true}, target_flags) ->
        invariant_error()

      not compatible_with_target?(result_desc, target_desc) ->
        invariant_error()

      true ->
        result
    end
  end

  defp compatible_with_target?(_result_desc, :undefined), do: true
  defp compatible_with_target?(_result_desc, nil), do: true

  defp compatible_with_target?(result_desc, target_desc) do
    cond do
      descriptor_field(result_desc, "configurable", true) == true ->
        true

      descriptor_field(target_desc, "configurable", true) == true ->
        true

      descriptor_field(result_desc, "writable", descriptor_field(target_desc, "writable", nil)) ==
        false and
        descriptor_field(target_desc, "writable", nil) == false and
        Map.has_key?(result_desc, "value") and
        Map.has_key?(target_desc, "value") and
          not Semantics.same_value?(Map.get(result_desc, "value"), Map.get(target_desc, "value")) ->
        false

      Map.has_key?(result_desc, "get") and Map.has_key?(target_desc, "get") and
          not Semantics.same_value?(Map.get(result_desc, "get"), Map.get(target_desc, "get")) ->
        false

      Map.has_key?(result_desc, "set") and Map.has_key?(target_desc, "set") and
          not Semantics.same_value?(Map.get(result_desc, "set"), Map.get(target_desc, "set")) ->
        false

      true ->
        true
    end
  end

  defp dispatch_fallback({:obj, _} = target, prop_name, _fallback) do
    InternalMethods.own_property(target, prop_name)
  end

  defp dispatch_fallback(target, prop_name, fallback), do: fallback.(target, prop_name)

  defp target_descriptor(target, prop_name) do
    case InternalMethods.own_property(target, prop_name) do
      {:obj, ref} -> Heap.get_obj(ref, %{})
      :undefined -> :undefined
      other -> other
    end
  end

  defp descriptor_field(desc, key, default), do: Map.get(desc, key, default)

  defp target_extensible?(target), do: InternalMethods.extensible?(target)

  defp invariant_error,
    do: JSThrow.type_error!("proxy getOwnPropertyDescriptor trap violates invariant")
end
