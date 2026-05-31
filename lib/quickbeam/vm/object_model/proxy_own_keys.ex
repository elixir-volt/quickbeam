defmodule QuickBEAM.VM.ObjectModel.ProxyOwnKeys do
  @moduledoc "Proxy [[OwnPropertyKeys]] trap result conversion and invariant validation."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Runtime, Value}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, ProxyDispatch, ProxyTrap}

  def dispatch({:obj, ref} = proxy, fallback) when is_function(fallback, 1) do
    case Heap.get_obj(ref, %{}) do
      %{proxy_target() => _target} = proxy_map ->
        proxy_fallback = fn target -> dispatch(target, fallback) end

        ProxyDispatch.with_trap(proxy_map, "ownKeys", proxy_fallback, fn target, handler, trap ->
          trap
          |> ProxyTrap.call([target], handler)
          |> result_list()
          |> validate_invariant(target)
        end)

      _ ->
        fallback.(proxy)
    end
  end

  def dispatch(target, fallback) when is_function(fallback, 1), do: fallback.(target)

  def result_list(result) do
    unless Value.object_like?(result) do
      JSThrow.type_error!("proxy ownKeys trap result is not an object")
    end

    length = result |> Get.get("length") |> Runtime.to_number() |> to_length()

    result =
      if length > 0 do
        for index <- 0..(length - 1), do: Get.get(result, Integer.to_string(index))
      else
        []
      end

    Enum.each(result, &validate_property_key!/1)
    result
  end

  defp to_length(:nan), do: 0
  defp to_length(:infinity), do: 9_007_199_254_740_991
  defp to_length(:neg_infinity), do: 0
  defp to_length(value) when is_number(value), do: value |> trunc() |> max(0)
  defp to_length(_), do: 0

  defp validate_property_key!(key) when is_binary(key), do: :ok
  defp validate_property_key!({:symbol, _}), do: :ok
  defp validate_property_key!({:symbol, _, _}), do: :ok

  defp validate_property_key!(_key),
    do: JSThrow.type_error!("proxy ownKeys trap result contains non-property key")

  def validate_invariant(trap_keys, target) do
    target_keys = InternalMethods.own_keys(target)

    missing_key =
      Enum.find(target_keys, fn key ->
        match?(%{configurable: false}, target_prop_desc(target, key)) and key not in trap_keys
      end)

    cond do
      Enum.uniq(trap_keys) != trap_keys ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      missing_key ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      non_extensible_key_mismatch?(target, target_keys, trap_keys) ->
        JSThrow.type_error!("proxy ownKeys trap violates invariant")

      true ->
        trap_keys
    end
  end

  defp non_extensible_key_mismatch?({:obj, ref}, target_keys, trap_keys),
    do: not Heap.extensible?(ref) and Enum.sort(target_keys) != Enum.sort(trap_keys)

  defp non_extensible_key_mismatch?(_target, _target_keys, _trap_keys), do: false

  defp target_prop_desc({:obj, ref}, key), do: Heap.get_prop_desc(ref, key)
  defp target_prop_desc(_target, _key), do: nil
end
