defmodule QuickBEAM.VM.ObjectModel.ProxyOwnKeys do
  @moduledoc "Proxy [[OwnPropertyKeys]] trap result conversion and invariant validation."

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods}

  def result_list(result) do
    length = Get.get(result, "length")

    if is_integer(length) and length > 0 do
      for index <- 0..(length - 1), do: Get.get(result, Integer.to_string(index))
    else
      []
    end
  end

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
