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
  def binary(:lt, left, right), do: compare(left, right, :lt)
  def binary(:lte, left, right), do: compare(left, right, :lte)
  def binary(:gt, left, right), do: compare(left, right, :gt)
  def binary(:gte, left, right), do: compare(left, right, :gte)
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
  def add(a, b), do: add_numbers(to_number(a), to_number(b))

  @doc "Normalizes JavaScript slice arguments to a bounded start and length."
  @spec slice_range(non_neg_integer(), [term()]) :: {non_neg_integer(), non_neg_integer()}
  def slice_range(size, arguments) do
    start = arguments |> List.first(0) |> normalize_slice_index(size)
    finish = arguments |> Enum.at(1, size) |> normalize_slice_index(size)
    {start, max(finish - start, 0)}
  end

  @doc "Implements numeric subtraction after JavaScript coercion."
  @spec subtract(term(), term()) :: term()
  def subtract(a, b), do: subtract_numbers(to_number(a), to_number(b))

  @doc "Implements numeric multiplication after JavaScript coercion."
  @spec multiply(term(), term()) :: term()
  def multiply(a, b), do: multiply_numbers(to_number(a), to_number(b))

  @doc "Implements numeric division with represented JavaScript infinities and NaN."
  @spec divide(term(), term()) :: term()
  def divide(a, b), do: divide_numbers(to_number(a), to_number(b))

  defp divide_numbers(:nan, _divisor), do: :nan
  defp divide_numbers(_dividend, :nan), do: :nan

  defp divide_numbers(dividend, divisor)
       when dividend in [:infinity, :neg_infinity] and divisor in [:infinity, :neg_infinity],
       do: :nan

  defp divide_numbers(dividend, divisor)
       when dividend in [:infinity, :neg_infinity] and is_number(divisor),
       do: signed_infinity(negative?(dividend) != negative?(divisor))

  defp divide_numbers(dividend, divisor)
       when is_number(dividend) and divisor in [:infinity, :neg_infinity],
       do: signed_zero(negative?(dividend) != negative?(divisor))

  defp divide_numbers(dividend, divisor) when dividend == 0 and divisor == 0, do: :nan

  defp divide_numbers(dividend, divisor) when divisor == 0,
    do: signed_infinity(negative?(dividend) != negative?(divisor))

  defp divide_numbers(dividend, divisor), do: dividend / divisor

  @doc "Implements numeric remainder after JavaScript coercion."
  @spec modulo(term(), term()) :: term()
  def modulo(a, b), do: remainder(to_number(a), to_number(b))

  defp remainder(:nan, _divisor), do: :nan
  defp remainder(_dividend, :nan), do: :nan
  defp remainder(dividend, _divisor) when dividend in [:infinity, :neg_infinity], do: :nan
  defp remainder(_dividend, divisor) when divisor == 0, do: :nan
  defp remainder(dividend, divisor) when divisor in [:infinity, :neg_infinity], do: dividend

  defp remainder(dividend, divisor) when is_integer(dividend) and is_integer(divisor) do
    case rem(dividend, divisor) do
      0 when dividend < 0 -> -0.0
      result -> result
    end
  end

  defp remainder(dividend, divisor), do: :math.fmod(dividend, divisor)

  @doc "Implements numeric exponentiation after JavaScript coercion."
  @spec power(term(), term()) :: term()
  def power(a, b), do: power_numbers(to_number(a), to_number(b))

  @doc "Implements unary numeric negation."
  @spec negate(term()) :: term()
  def negate(value), do: negate_number(to_number(value))

  @doc "Compares strings lexically or other values numerically."
  @spec compare(term(), term(), :lt | :lte | :gt | :gte) :: boolean()
  def compare(a, b, operation) when is_binary(a) and is_binary(b),
    do: compare_order(operation, ordering(a, b))

  def compare(a, b, operation) do
    case {to_number(a), to_number(b)} do
      {:nan, _right} -> false
      {_left, :nan} -> false
      {left, right} -> compare_order(operation, ordering(left, right))
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

  def to_number(value) when is_binary(value), do: value |> String.trim() |> parse_number()

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
  def to_string_value(value) when is_float(value) and value == 0.0, do: "0"

  def to_string_value(value)
      when is_float(value) and value > -1.0e21 and value < 1.0e21 and trunc(value) == value,
      do: value |> trunc() |> Integer.to_string()

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

  defp parse_number(""), do: 0
  defp parse_number("Infinity"), do: :infinity
  defp parse_number("+Infinity"), do: :infinity
  defp parse_number("-Infinity"), do: :neg_infinity
  defp parse_number("0x" <> digits), do: parse_integer(digits, 16)
  defp parse_number("0X" <> digits), do: parse_integer(digits, 16)
  defp parse_number("0b" <> digits), do: parse_integer(digits, 2)
  defp parse_number("0B" <> digits), do: parse_integer(digits, 2)
  defp parse_number("0o" <> digits), do: parse_integer(digits, 8)
  defp parse_number("0O" <> digits), do: parse_integer(digits, 8)

  defp parse_number(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid_integer -> parse_float(value)
    end
  end

  defp parse_integer(value, base) do
    case Integer.parse(value, base) do
      {integer, ""} -> integer
      _invalid_integer -> :nan
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _invalid_float -> :nan
    end
  end

  defp normalize_slice_index(value, size) do
    case to_number(value) do
      :infinity -> size
      :neg_infinity -> 0
      :nan -> 0
      index when is_number(index) -> normalize_slice_integer(trunc(index), size)
    end
  end

  defp normalize_slice_integer(index, size) when index < 0, do: max(size + index, 0)
  defp normalize_slice_integer(index, size), do: min(index, size)

  defp add_numbers(:nan, _right), do: :nan
  defp add_numbers(_left, :nan), do: :nan
  defp add_numbers(:infinity, :neg_infinity), do: :nan
  defp add_numbers(:neg_infinity, :infinity), do: :nan
  defp add_numbers(:infinity, _right), do: :infinity
  defp add_numbers(_left, :infinity), do: :infinity
  defp add_numbers(:neg_infinity, _right), do: :neg_infinity
  defp add_numbers(_left, :neg_infinity), do: :neg_infinity
  defp add_numbers(left, right), do: left + right

  defp subtract_numbers(left, right), do: add_numbers(left, negate_number(right))

  defp multiply_numbers(:nan, _right), do: :nan
  defp multiply_numbers(_left, :nan), do: :nan

  defp multiply_numbers(left, right)
       when left in [:infinity, :neg_infinity] or right in [:infinity, :neg_infinity] do
    if zero?(left) or zero?(right),
      do: :nan,
      else: signed_infinity(negative?(left) != negative?(right))
  end

  defp multiply_numbers(left, right), do: left * right

  defp power_numbers(_base, exponent) when exponent == 0, do: 1.0
  defp power_numbers(:nan, _exponent), do: :nan
  defp power_numbers(_base, :nan), do: :nan

  defp power_numbers(base, exponent) when exponent in [:infinity, :neg_infinity] do
    power_infinite_exponent(base, exponent)
  end

  defp power_numbers(base, exponent) when base in [:infinity, :neg_infinity] do
    power_infinite_base(base, exponent)
  end

  defp power_numbers(base, exponent) when base == 0 and exponent < 0,
    do: signed_infinity(negative?(base) and odd_integer?(exponent))

  defp power_numbers(base, exponent) do
    :math.pow(base, exponent)
  rescue
    ArithmeticError -> :nan
  end

  defp power_infinite_exponent(base, exponent) do
    magnitude = if base in [:infinity, :neg_infinity], do: :infinity, else: abs(base)

    case {magnitude, exponent} do
      {magnitude, _exponent} when magnitude == 1 -> :nan
      {:infinity, :infinity} -> :infinity
      {:infinity, :neg_infinity} -> 0.0
      {magnitude, :infinity} when magnitude > 1 -> :infinity
      {_magnitude, :infinity} -> 0.0
      {magnitude, :neg_infinity} when magnitude > 1 -> 0.0
      {_magnitude, :neg_infinity} -> :infinity
    end
  end

  defp power_infinite_base(base, exponent) when exponent > 0 do
    negative_result? = base == :neg_infinity and odd_integer?(exponent)
    signed_infinity(negative_result?)
  end

  defp power_infinite_base(_base, _exponent), do: 0.0

  defp negate_number(:nan), do: :nan
  defp negate_number(:infinity), do: :neg_infinity
  defp negate_number(:neg_infinity), do: :infinity
  defp negate_number(number) when number == 0, do: signed_zero(not negative?(number))
  defp negate_number(number), do: -number

  defp ordering(left, right) when left == right, do: :eq
  defp ordering(:neg_infinity, _right), do: :lt
  defp ordering(_left, :neg_infinity), do: :gt
  defp ordering(:infinity, _right), do: :gt
  defp ordering(_left, :infinity), do: :lt
  defp ordering(left, right) when left < right, do: :lt
  defp ordering(_left, _right), do: :gt

  defp compare_order(:lt, :lt), do: true
  defp compare_order(:lte, order) when order in [:lt, :eq], do: true
  defp compare_order(:gt, :gt), do: true
  defp compare_order(:gte, order) when order in [:gt, :eq], do: true
  defp compare_order(_operation, _order), do: false

  defp odd_integer?(value) when is_integer(value), do: rem(value, 2) != 0

  defp odd_integer?(value) when is_float(value) and trunc(value) == value,
    do: rem(trunc(value), 2) != 0

  defp odd_integer?(_value), do: false

  defp signed_infinity(true), do: :neg_infinity
  defp signed_infinity(false), do: :infinity
  defp signed_zero(true), do: -0.0
  defp signed_zero(false), do: 0.0

  defp negative?(:neg_infinity), do: true

  defp negative?(value) when is_float(value) and value == 0.0 do
    <<sign::1, _magnitude::63>> = <<value::float>>
    sign == 1
  end

  defp negative?(value) when is_number(value), do: value < 0
  defp negative?(_value), do: false

  defp zero?(value) when is_number(value), do: value == 0
  defp zero?(_value), do: false

  defp signed32(value) do
    value = band(value, 0xFFFFFFFF)
    if value >= 0x80000000, do: value - 0x100000000, else: value
  end
end
