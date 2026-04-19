defmodule QuickBEAM.BeamVM.Heap.Keys do
  @moduledoc false

  @proto "__proto__"
  @promise_state "__promise_state__"
  @promise_value "__promise_value__"
  @map_data "__map_data__"
  @set_data "__set_data__"
  @typed_array "__typed_array__"
  @date_ms "__date_ms__"
  @proxy_target "__proxy_target__"
  @proxy_handler "__proxy_handler__"
  @buffer "__buffer__"
  @key_order :__key_order__
  @primitive_value "__primitive_value__"
  @type_key "__type__"
  @offset "__offset__"

  defmacro proto, do: @proto
  defmacro promise_state, do: @promise_state
  defmacro promise_value, do: @promise_value
  defmacro map_data, do: @map_data
  defmacro set_data, do: @set_data
  defmacro typed_array, do: @typed_array
  defmacro date_ms, do: @date_ms
  defmacro proxy_target, do: @proxy_target
  defmacro proxy_handler, do: @proxy_handler
  defmacro buffer, do: @buffer
  defmacro key_order, do: @key_order
  defmacro primitive_value, do: @primitive_value
  defmacro type_key, do: @type_key
  defmacro offset, do: @offset

  def internal?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  def internal?(_), do: false
end
