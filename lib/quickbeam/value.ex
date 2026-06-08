defmodule QuickBEAM.Value do
  @moduledoc """
  Public guards and helpers for JavaScript values that surface through the BEAM VM.

  Most users receive ordinary Elixir values from NIF-backed runtimes. These
  helpers are intended for BEAM-mode APIs, tests, and low-level integrations that
  may observe VM-native representations such as objects, functions, symbols, and
  BigInts.
  """

  alias QuickBEAM.VM.Value, as: VMValue

  @type t :: VMValue.js_value()
  @type object :: VMValue.object()
  @type symbol :: VMValue.symbol()
  @type bigint :: VMValue.bigint()

  defguard is_object(value)
           when is_tuple(value) and tuple_size(value) == 2 and elem(value, 0) == :obj

  defguard is_symbol(value)
           when is_tuple(value) and (tuple_size(value) == 2 or tuple_size(value) == 3) and
                  elem(value, 0) == :symbol

  defguard is_bigint(value)
           when is_tuple(value) and tuple_size(value) == 2 and elem(value, 0) == :bigint

  defguard is_function(value)
           when (is_tuple(value) and tuple_size(value) >= 1 and
                   elem(value, 0) in [:builtin, :closure, :bound]) or
                  is_struct(value, QuickBEAM.VM.Function)

  defguard is_nullish(value) when value == nil or value == :undefined

  @doc "Returns true when the value has ECMAScript object semantics."
  def object?(value), do: VMValue.object_like?(value)

  @doc "Returns true when the value is callable."
  def function?(value), do: VMValue.function_like?(value)

  @doc "Returns true when the value is null or undefined."
  def nullish?(value), do: VMValue.nullish?(value)

  @doc "Returns true when the value is a JavaScript Symbol representation."
  def symbol?(value), do: VMValue.symbol?(value)

  @doc "Returns true when the value is a JavaScript BigInt representation."
  def bigint?(value), do: match?({:bigint, _}, value)

  @doc "Returns the Symbol description payload."
  def symbol_description(symbol), do: VMValue.symbol_name(symbol)

  @doc "Wraps an integer as a BEAM-mode JavaScript BigInt value."
  def bigint(integer) when is_integer(integer), do: {:bigint, integer}
end
