defmodule QuickBEAM.VM.Runtime.TypedArrayCoercion do
  @moduledoc "Numeric and BigInt coercion helpers for TypedArray operations."

  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Semantics.Coercion

  def element_value(value, type) when type in [:bigint64, :biguint64],
    do: {:bigint, bigint_value(value)}

  def element_value(value, _type), do: Runtime.to_number(value)

  def bigint_value({:bigint, n}), do: n
  def bigint_value(true), do: 1
  def bigint_value(false), do: 0

  def bigint_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_bigint_string()
    |> case do
      {:ok, n} -> n
      :error -> JSThrow.syntax_error!("Cannot convert value to BigInt")
    end
  end

  def bigint_value({:obj, _} = value),
    do: value |> Coercion.to_primitive("number") |> bigint_value()

  def bigint_value(_), do: JSThrow.type_error!("Cannot convert value to BigInt")

  def integer_or_infinity({:bigint, _}),
    do: JSThrow.type_error!("Cannot convert BigInt to number")

  def integer_or_infinity(value) do
    case Runtime.to_number(value) do
      :infinity -> :infinity
      :neg_infinity -> :neg_infinity
      :nan -> 0
      number when is_number(number) -> trunc(number)
      _ -> 0
    end
  end

  def index(value) when is_nullish(value), do: 0

  def index(value) do
    case integer_or_infinity(value) do
      index when index in [:infinity, :neg_infinity] -> JSThrow.range_error!("Invalid index")
      index when index < 0 -> JSThrow.range_error!("Invalid index")
      index -> index
    end
  end

  defp parse_bigint_string(""), do: {:ok, 0}
  defp parse_bigint_string("0x" <> digits), do: parse_bigint_digits(digits, 16)
  defp parse_bigint_string("0X" <> digits), do: parse_bigint_digits(digits, 16)
  defp parse_bigint_string("0o" <> digits), do: parse_bigint_digits(digits, 8)
  defp parse_bigint_string("0O" <> digits), do: parse_bigint_digits(digits, 8)
  defp parse_bigint_string("0b" <> digits), do: parse_bigint_digits(digits, 2)
  defp parse_bigint_string("0B" <> digits), do: parse_bigint_digits(digits, 2)
  defp parse_bigint_string("+" <> digits), do: parse_bigint_digits(digits, 10)

  defp parse_bigint_string("-" <> digits) do
    case parse_bigint_digits(digits, 10) do
      {:ok, n} -> {:ok, -n}
      :error -> :error
    end
  end

  defp parse_bigint_string(digits), do: parse_bigint_digits(digits, 10)

  defp parse_bigint_digits("", _base), do: :error

  defp parse_bigint_digits(digits, base) do
    case Integer.parse(digits, base) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
end
