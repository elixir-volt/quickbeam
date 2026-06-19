defmodule QuickBEAM.VM.Semantics.PropertyAccess do
  @moduledoc "Shared JavaScript property-access boundary for nullish checks and key conversion."

  alias QuickBEAM.VM.{Heap, Value}
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, PropertyKey, Put}

  def require_object_for_property!(nil, key),
    do: nullish_property_error!("null", key)

  def require_object_for_property!(:undefined, key),
    do: nullish_property_error!("undefined", key)

  def require_object_for_property!(value, _key), do: value

  def to_property_key(value), do: PropertyKey.to_property_key(value)

  def to_property_key_for_access(receiver, key) do
    require_object_for_property!(receiver, key)
    to_property_key(key)
  end

  def get_property(_ctx \\ nil, receiver, key) do
    prop_key = to_property_key_for_access(receiver, key)
    InternalMethods.get(receiver, prop_key)
  end

  def set_property(ctx \\ nil, receiver, key, value) do
    prop_key = to_property_key_for_access(receiver, key)

    if symbol_primitive?(receiver) and strict_context?(ctx) do
      throw(
        {:js_throw, Heap.make_error("Cannot create property on Symbol primitive", "TypeError")}
      )
    else
      Put.put_element(receiver, prop_key, value)
    end
  end

  defp symbol_primitive?(value), do: Value.symbol?(value)

  defp strict_context?(ctx), do: Value.strict_context?(ctx)

  defp nullish_property_error!(nullish, key) do
    throw(
      {:js_throw,
       Heap.make_error(
         "Cannot read properties of #{nullish} (reading '#{format_key(key)}')",
         "TypeError"
       )}
    )
  end

  defp format_key({:symbol, _, _} = key), do: Value.symbol_name(key)
  defp format_key({:symbol, _} = key), do: Value.symbol_name(key)
  defp format_key(key) when is_binary(key), do: key
  defp format_key(key), do: QuickBEAM.VM.Semantics.Values.stringify(key)
end
