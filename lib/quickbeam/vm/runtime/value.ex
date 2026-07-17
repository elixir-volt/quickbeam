defmodule QuickBEAM.VM.Runtime.Value do
  @moduledoc """
  Implements canonical JavaScript value coercion and primitive operations.

  Opcode dispatch, built-ins, properties, and future compiled code use this
  module for truthiness, equality, arithmetic, comparisons, bitwise conversion,
  `typeof`, string conversion, and UTF-16 string operations.
  """

  import Bitwise

  alias QuickBEAM.VM.Runtime.String.UTF16

  @doc "Returns JavaScript boolean coercion for a VM value."
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(:undefined), do: false
  def truthy?(:nan), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(value) when is_float(value) and value == 0.0, do: false
  def truthy?(""), do: false
  def truthy?(_value), do: true

  @doc "Implements JavaScript strict equality for represented VM values."
  @spec strict_equal?(term(), term()) :: boolean()
  def strict_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  def strict_equal?(:nan, _value), do: false
  def strict_equal?(_value, :nan), do: false
  def strict_equal?(a, b), do: a === b

  @doc "Implements the supported JavaScript abstract equality coercions."
  @spec abstract_equal?(term(), term()) :: boolean()
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

  @doc "Applies a canonical unary value operation."
  @spec unary(atom(), term()) :: term()
  def unary(:neg, value), do: negate(value)
  def unary(:plus, value), do: to_number(value)
  def unary(:not, value), do: bitwise_not(value)
  def unary(:lnot, value), do: not truthy?(value)
  def unary(:inc, value), do: add(value, 1)
  def unary(:dec, value), do: subtract(value, 1)
  def unary(:is_undefined_or_null, value), do: value in [:undefined, nil]
  def unary(:is_undefined, value), do: value == :undefined
  def unary(:is_null, value), do: is_nil(value)

  @doc "Applies a canonical binary value operation."
  @spec binary(atom(), term(), term()) :: term()
  def binary(:add, left, right), do: add(left, right)
  def binary(:sub, left, right), do: subtract(left, right)
  def binary(:mul, left, right), do: multiply(left, right)
  def binary(:div, left, right), do: divide(left, right)
  def binary(:mod, left, right), do: modulo(left, right)
  def binary(:pow, left, right), do: power(left, right)
  def binary(:lt, left, right), do: compare(left, right, &Kernel.</2)
  def binary(:lte, left, right), do: compare(left, right, &Kernel.<=/2)
  def binary(:gt, left, right), do: compare(left, right, &Kernel.>/2)
  def binary(:gte, left, right), do: compare(left, right, &Kernel.>=/2)
  def binary(:eq, left, right), do: abstract_equal?(left, right)
  def binary(:neq, left, right), do: not abstract_equal?(left, right)
  def binary(:strict_eq, left, right), do: strict_equal?(left, right)
  def binary(:strict_neq, left, right), do: not strict_equal?(left, right)
  def binary(:and, left, right), do: bitwise(left, right, &band/2)
  def binary(:or, left, right), do: bitwise(left, right, &bor/2)
  def binary(:xor, left, right), do: bitwise(left, right, &bxor/2)
  def binary(:shl, left, right), do: shift_left(left, right)
  def binary(:sar, left, right), do: shift_right(left, right)
  def binary(:shr, left, right), do: shift_right_unsigned(left, right)

  @doc "Implements JavaScript addition, including string concatenation."
  @spec add(term(), term()) :: term()
  def add(a, b) when is_binary(a) or is_binary(b), do: to_string_value(a) <> to_string_value(b)
  def add(a, b), do: numeric_binary(a, b, &Kernel.+/2)

  @doc "Implements numeric subtraction after JavaScript coercion."
  @spec subtract(term(), term()) :: term()
  def subtract(a, b), do: numeric_binary(a, b, &Kernel.-/2)

  @doc "Implements numeric multiplication after JavaScript coercion."
  @spec multiply(term(), term()) :: term()
  def multiply(a, b), do: numeric_binary(a, b, &Kernel.*/2)

  @doc "Implements numeric division with represented JavaScript infinities and NaN."
  @spec divide(term(), term()) :: term()
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

  @doc "Implements numeric remainder after JavaScript coercion."
  @spec modulo(term(), term()) :: term()
  def modulo(a, b) do
    a = to_number(a)
    b = to_number(b)

    cond do
      a == :nan or b == :nan or b == 0 -> :nan
      is_integer(a) and is_integer(b) -> rem(a, b)
      true -> :math.fmod(a, b)
    end
  end

  @doc "Implements numeric exponentiation after JavaScript coercion."
  @spec power(term(), term()) :: term()
  def power(a, b) do
    case {to_number(a), to_number(b)} do
      {:nan, _} -> :nan
      {_, :nan} -> :nan
      {left, right} -> :math.pow(left, right)
    end
  end

  @doc "Implements unary numeric negation."
  @spec negate(term()) :: term()
  def negate(value) do
    case to_number(value) do
      :nan -> :nan
      number -> -number
    end
  end

  @doc "Compares strings lexically or other values numerically."
  @spec compare(term(), term(), (term(), term() -> boolean())) :: boolean()
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

  @doc "Applies a binary operation to JavaScript `Int32` coercions."
  @spec bitwise(term(), term(), (integer(), integer() -> integer())) :: integer()
  def bitwise(a, b, operation), do: operation.(to_int32(a), to_int32(b))

  @doc "Implements signed 32-bit left shift."
  @spec shift_left(term(), term()) :: integer()
  def shift_left(a, b), do: bsl(to_int32(a), band(to_int32(b), 31))

  @doc "Implements signed 32-bit right shift."
  @spec shift_right(term(), term()) :: integer()
  def shift_right(a, b), do: bsr(to_int32(a), band(to_int32(b), 31))

  @doc "Implements unsigned 32-bit right shift."
  @spec shift_right_unsigned(term(), term()) :: non_neg_integer()
  def shift_right_unsigned(a, b), do: bsr(band(to_int32(a), 0xFFFFFFFF), band(to_int32(b), 31))

  @doc "Implements 32-bit bitwise complement."
  @spec bitwise_not(term()) :: integer()
  def bitwise_not(value), do: bnot(to_int32(value))

  @doc "Returns the primitive JavaScript `typeof` classification."
  @spec typeof(term()) :: String.t()
  def typeof(:undefined), do: "undefined"
  def typeof(nil), do: "object"
  def typeof(value) when is_boolean(value), do: "boolean"

  def typeof(value) when is_number(value) or value in [:nan, :infinity, :neg_infinity],
    do: "number"

  def typeof(value) when is_binary(value), do: "string"
  def typeof(%QuickBEAM.VM.Runtime.Symbol{}), do: "symbol"
  def typeof(%QuickBEAM.VM.Program.Function{}), do: "function"
  def typeof(%QuickBEAM.VM.Runtime.Reference{}), do: "object"
  def typeof(%QuickBEAM.VM.Runtime.Promise.Reference{}), do: "object"
  def typeof(%QuickBEAM.VM.Runtime.RegExp{}), do: "object"
  def typeof({:closure, %QuickBEAM.VM.Program.Function{}, _captures}), do: "function"
  def typeof(_value), do: "object"

  @doc "Coerces a represented JavaScript primitive to a number."
  @spec to_number(term()) :: number() | :nan | :infinity | :neg_infinity
  def to_number(value) when is_number(value), do: value
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: 0
  def to_number(:undefined), do: :nan
  def to_number(:nan), do: :nan
  def to_number(:infinity), do: :infinity
  def to_number(:neg_infinity), do: :neg_infinity
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

  @doc "Coerces a represented JavaScript value to signed 32-bit integer form."
  @spec to_int32(term()) :: integer()
  def to_int32(value) do
    case to_number(value) do
      number when is_integer(number) -> signed32(number)
      number when is_float(number) -> signed32(trunc(number))
      _ -> 0
    end
  end

  @doc "Coerces a represented JavaScript value to its string form."
  @spec to_string_value(term()) :: String.t()
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

  @doc "Returns a JavaScript string's UTF-16 code-unit length."
  @spec string_length(String.t()) :: non_neg_integer()
  def string_length(value), do: UTF16.length(value)

  @doc "Returns one JavaScript string code unit encoded as WTF-8."
  @spec string_at(String.t(), integer()) :: String.t() | :undefined
  def string_at(value, index), do: UTF16.at(value, index)

  @doc "Slices a JavaScript string by UTF-16 code units."
  @spec string_slice(String.t(), integer(), non_neg_integer()) :: String.t()
  def string_slice(value, start, length), do: UTF16.slice(value, start, length)

  @doc "Returns a JavaScript string's UTF-16 code unit at an index."
  @spec string_char_code_at(String.t(), integer()) :: non_neg_integer() | :nan
  def string_char_code_at(value, index), do: UTF16.char_code_at(value, index)

  @doc "Builds a JavaScript string from UTF-16 code units."
  @spec string_from_units([integer()]) :: String.t()
  def string_from_units(units), do: UTF16.from_units(units)

  @doc "Implements `String.fromCharCode` coercion for represented values."
  @spec string_from_char_codes([term()]) :: String.t()
  def string_from_char_codes(values) do
    values
    |> Enum.map(&band(to_int32(&1), 0xFFFF))
    |> string_from_units()
  end

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
