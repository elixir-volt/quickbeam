defmodule QuickBEAM.VM.Heap.Keys do
  @moduledoc "Canonical internal property keys shared across heap, runtime, and object-model modules."

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

  @internal_slots [
    @proto,
    @promise_state,
    @promise_value,
    @map_data,
    @set_data,
    @typed_array,
    @date_ms,
    @proxy_target,
    @proxy_handler,
    @buffer,
    @key_order,
    @primitive_value,
    @type_key,
    @offset
  ]

  @doc "Internal object prototype property key."
  defmacro proto, do: @proto
  @doc "Internal promise state property key."
  defmacro promise_state, do: @promise_state
  @doc "Internal promise value property key."
  defmacro promise_value, do: @promise_value
  @doc "Internal Map storage property key."
  defmacro map_data, do: @map_data
  @doc "Internal Set storage property key."
  defmacro set_data, do: @set_data
  @doc "Internal typed-array marker property key."
  defmacro typed_array, do: @typed_array
  defmacro date_ms, do: @date_ms
  defmacro proxy_target, do: @proxy_target
  defmacro proxy_handler, do: @proxy_handler
  @doc "Internal ArrayBuffer backing binary property key."
  defmacro buffer, do: @buffer
  defmacro key_order, do: @key_order
  defmacro primitive_value, do: @primitive_value
  defmacro type_key, do: @type_key
  defmacro offset, do: @offset

  @doc "Returns true when a property key uses the VM internal `__name__` convention."
  def internal?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and String.ends_with?(key, "__")

  def internal?(_), do: false

  @doc "Returns true when a property key is in QuickBEAM's reserved internal namespace."
  def internal_namespace?(key) when is_binary(key), do: String.starts_with?(key, "__")
  def internal_namespace?(_), do: false

  @doc "Returns true when a key denotes VM internal slot storage rather than a JS-visible property."
  def internal_slot?(key) when key in @internal_slots, do: true
  def internal_slot?({:internal, _}), do: true
  def internal_slot?(key), do: internal?(key)
end
