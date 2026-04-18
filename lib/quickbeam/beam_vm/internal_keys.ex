defmodule QuickBEAM.BeamVM.InternalKeys do
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

  def proto, do: @proto
  def promise_state, do: @promise_state
  def promise_value, do: @promise_value
  def map_data, do: @map_data
  def set_data, do: @set_data
  def typed_array, do: @typed_array
  def date_ms, do: @date_ms
  def proxy_target, do: @proxy_target
  def proxy_handler, do: @proxy_handler
  def buffer, do: @buffer
  def key_order, do: @key_order
  def primitive_value, do: @primitive_value
  def type_key, do: @type_key
  def offset, do: @offset

  def internal?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  def internal?(_), do: false
end
