defmodule QuickBEAM.VM.Value do
  @moduledoc false

  import Bitwise

  def truthy?(nil), do: false
  def truthy?(:undefined), do: false
  def truthy?(:nan), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(value) when is_float(value) and value == 0.0, do: false
  def truthy?(""), do: false
  def truthy?(_value), do: true

  def strict_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  def strict_equal?(:nan, _value), do: false
  def strict_equal?(_value, :nan), do: false
  def strict_equal?(a, b), do: a === b

  def abstract_equal?(nil, :undefined), do: true
  def abstract_equal?(:undefined, nil), do: true
  def abstract_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  def abstract_equal?(a, b) when is_boolean(a), do: abstract_equal?(to_number(a), b)
  def abstract_equal?(a, b) when is_boolean(b), do: abstract_equal?(a, to_number(b))

  def abstract_equal?(a, b) when is_number(a) and is_binary(b),
    do: abstract_equal?(a, to_number(b))

  def abstract_equal?(a, b) when is_binary(a) and is_number(b),
    do: abstract_equal?(to_number(a), b)

  def abstract_equal?(a, b), do: strict_equal?(a, b)

  def add(a, b) when is_binary(a) or is_binary(b), do: to_string_value(a) <> to_string_value(b)
  def add(a, b), do: numeric_binary(a, b, &Kernel.+/2)
  def subtract(a, b), do: numeric_binary(a, b, &Kernel.-/2)
  def multiply(a, b), do: numeric_binary(a, b, &Kernel.*/2)

  def divide(a, b) do
    a = to_number(a)
    b = to_number(b)

    cond do
      a == :nan or b == :nan -> :nan
      b == 0 and a == 0 -> :nan
      b == 0 and a > 0 -> :infinity
      b == 0 and a < 0 -> :neg_infinity
      true -> a / b
    end
  end

  def modulo(a, b) do
    a = to_number(a)
    b = to_number(b)

    cond do
      a == :nan or b == :nan or b == 0 -> :nan
      is_integer(a) and is_integer(b) -> rem(a, b)
      true -> :math.fmod(a, b)
    end
  end

  def power(a, b) do
    case {to_number(a), to_number(b)} do
      {:nan, _} -> :nan
      {_, :nan} -> :nan
      {left, right} -> :math.pow(left, right)
    end
  end

  def negate(value) do
    case to_number(value) do
      :nan -> :nan
      number -> -number
    end
  end

  def compare(a, b, operation) do
    {a, b} =
      if is_binary(a) and is_binary(b),
        do: {a, b},
        else: {to_number(a), to_number(b)}

    if a == :nan or b == :nan do
      false
    else
      operation.(a, b)
    end
  end

  def bitwise(a, b, operation), do: operation.(to_int32(a), to_int32(b))
  def shift_left(a, b), do: bsl(to_int32(a), band(to_int32(b), 31))
  def shift_right(a, b), do: bsr(to_int32(a), band(to_int32(b), 31))
  def shift_right_unsigned(a, b), do: bsr(band(to_int32(a), 0xFFFFFFFF), band(to_int32(b), 31))
  def bitwise_not(value), do: bnot(to_int32(value))

  def typeof(:undefined), do: "undefined"
  def typeof(nil), do: "object"
  def typeof(value) when is_boolean(value), do: "boolean"

  def typeof(value) when is_number(value) or value in [:nan, :infinity, :neg_infinity],
    do: "number"

  def typeof(value) when is_binary(value), do: "string"
  def typeof(%QuickBEAM.VM.Function{}), do: "function"
  def typeof(%QuickBEAM.VM.Reference{}), do: "object"
  def typeof(%QuickBEAM.VM.PromiseReference{}), do: "object"
  def typeof(%QuickBEAM.VM.RegExp{}), do: "object"
  def typeof({:closure, %QuickBEAM.VM.Function{}, _captures}), do: "function"
  def typeof(_value), do: "object"

  def to_number(value) when is_number(value), do: value
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: 0
  def to_number(:undefined), do: :nan
  def to_number(:nan), do: :nan
  def to_number(""), do: 0

  def to_number(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> :nan
        end
    end
  end

  def to_number(_value), do: :nan

  def to_int32(value) do
    case to_number(value) do
      number when is_integer(number) -> signed32(number)
      number when is_float(number) -> signed32(trunc(number))
      _ -> 0
    end
  end

  def to_string_value(:undefined), do: "undefined"
  def to_string_value(nil), do: "null"
  def to_string_value(true), do: "true"
  def to_string_value(false), do: "false"
  def to_string_value(:nan), do: "NaN"
  def to_string_value(:infinity), do: "Infinity"
  def to_string_value(:neg_infinity), do: "-Infinity"
  def to_string_value(value) when is_integer(value), do: Integer.to_string(value)
  def to_string_value(value) when is_float(value), do: Float.to_string(value)
  def to_string_value(value) when is_binary(value), do: value
  def to_string_value(_value), do: "[object Object]"

  defp numeric_binary(a, b, operation) do
    case {to_number(a), to_number(b)} do
      {:nan, _} -> :nan
      {_, :nan} -> :nan
      {left, right} -> operation.(left, right)
    end
  end

  defp signed32(value) do
    value = band(value, 0xFFFFFFFF)
    if value >= 0x80000000, do: value - 0x100000000, else: value
  end
end
