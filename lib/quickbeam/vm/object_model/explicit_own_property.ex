defmodule QuickBEAM.VM.ObjectModel.ExplicitOwnProperty do
  @moduledoc "Checks whether a value has an explicit own property whose value may be undefined."

  import QuickBEAM.VM.Heap.Keys, only: [proxy_target: 0, typed_array: 0]

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.TypedArray

  def present?({:regexp, _, _, ref}, key), do: RegexpState.has_property?(ref, key)

  def present?({:obj, ref}, key) do
    case Heap.get_obj_raw(ref) do
      {:qb_arr, _} -> Heap.get_prop_desc(ref, key) != nil
      data when is_list(data) -> Heap.get_prop_desc(ref, key) != nil
      raw when is_tuple(raw) -> Heap.shape?(raw) and match?({:ok, _}, Heap.raw_fetch(raw, key))
      %{typed_array() => true} -> typed_array_property_present?(ref, key)
      map when is_map(map) -> not Map.has_key?(map, proxy_target()) and Map.has_key?(map, key)
      _ -> false
    end
  end

  def present?(%QuickBEAM.VM.Function{is_strict_mode: false}, key)
      when key in ["caller", "arguments"],
      do: true

  def present?({:closure, _, %QuickBEAM.VM.Function{is_strict_mode: false}}, key)
      when key in ["caller", "arguments"],
      do: true

  def present?(value, key) when is_tuple(value) or is_struct(value),
    do: Heap.get_ctor_prop_desc(value, key) != nil

  def present?(_value, _key), do: false

  defp typed_array_property_present?(ref, key),
    do:
      TypedArray.integer_index_key(key) != :not_integer_index or
        Map.has_key?(Heap.get_obj(ref, %{}), key)
end
