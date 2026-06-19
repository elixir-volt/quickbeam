defmodule QuickBEAM.VM.Runtime.Globals.Numeric do
  @moduledoc "Global numeric functions: `parseInt`, `parseFloat`, `isNaN`, `isFinite`, and related utilities."
  alias QuickBEAM.VM.Semantics.{Coercion, Values}

  @doc "Implements JavaScript `parseInt` semantics."
  def parse_int(args, _) do
    input = args |> Enum.at(0, :undefined) |> Values.stringify() |> String.trim_leading()
    radix = args |> Enum.at(1, :undefined) |> parse_int_radix()
    {sign, digits} = parse_sign(input)
    {base, digits} = parse_int_base(radix, digits)

    if base < 2 or base > 36 do
      :nan
    else
      case parse_digits(digits, base) do
        {n, _rest} -> sign * n
        :error -> :nan
      end
    end
  end

  @doc "Implements JavaScript `parseFloat` semantics."
  def parse_float(args, _) do
    input = args |> Enum.at(0, :undefined) |> Values.stringify() |> String.trim_leading()

    cond do
      String.starts_with?(input, "Infinity") or String.starts_with?(input, "+Infinity") ->
        :infinity

      String.starts_with?(input, "-Infinity") ->
        :neg_infinity

      true ->
        case Regex.run(~r/^[+-]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][+-]?\d+)?/, input) do
          [number] -> parse_float_number(number)
          _ -> :nan
        end
    end
  end

  defp parse_int_radix(:undefined), do: 0
  defp parse_int_radix(:nan), do: 0
  defp parse_int_radix(:infinity), do: 0
  defp parse_int_radix(:neg_infinity), do: 0

  defp parse_int_radix(value) do
    value
    |> Values.to_number()
    |> to_int32()
  end

  defp to_int32(number) when is_number(number) do
    int = trunc(number)
    int32 = Integer.mod(int, 0x1_0000_0000)
    if int32 >= 0x8000_0000, do: int32 - 0x1_0000_0000, else: int32
  end

  defp to_int32(_), do: 0

  defp parse_sign("+" <> rest), do: {1, rest}
  defp parse_sign("-" <> rest), do: {-1, rest}
  defp parse_sign(rest), do: {1, rest}

  defp parse_int_base(0, "0x" <> rest), do: {16, rest}
  defp parse_int_base(0, "0X" <> rest), do: {16, rest}
  defp parse_int_base(0, rest), do: {10, rest}
  defp parse_int_base(16, "0x" <> rest), do: {16, rest}
  defp parse_int_base(16, "0X" <> rest), do: {16, rest}
  defp parse_int_base(base, rest), do: {base, rest}

  defp parse_digits(string, base) do
    string
    |> String.to_charlist()
    |> Enum.reduce_while({0, false}, fn char, {acc, seen?} ->
      digit = digit_value(char)

      if digit >= 0 and digit < base do
        {:cont, {acc * base + digit, true}}
      else
        {:halt, {acc, seen?}}
      end
    end)
    |> case do
      {value, true} -> {value, ""}
      _ -> :error
    end
  end

  defp digit_value(char) when char in ?0..?9, do: char - ?0
  defp digit_value(char) when char in ?a..?z, do: char - ?a + 10
  defp digit_value(char) when char in ?A..?Z, do: char - ?A + 10
  defp digit_value(_), do: -1

  defp parse_float_number(number) do
    number = normalize_float_token(number)

    case Float.parse(number) do
      {value, ""} when value == 0.0 ->
        if String.starts_with?(number, "-"), do: -0.0, else: value

      {value, ""} ->
        value

      _ ->
        :nan
    end
  end

  defp normalize_float_token("+." <> rest), do: ensure_float_fraction("+0." <> rest)
  defp normalize_float_token("-." <> rest), do: ensure_float_fraction("-0." <> rest)
  defp normalize_float_token("." <> rest), do: ensure_float_fraction("0." <> rest)
  defp normalize_float_token(number), do: ensure_float_fraction(number)

  defp ensure_float_fraction(number) do
    cond do
      String.ends_with?(number, ".") -> String.replace_suffix(number, ".", ".0")
      String.contains?(number, ".e") -> String.replace(number, ".e", ".0e", global: false)
      String.contains?(number, ".E") -> String.replace(number, ".E", ".0E", global: false)
      true -> number
    end
  end

  @doc "Returns whether a VM number is JavaScript NaN."
  def nan?([:infinity | _], _), do: false
  def nan?([:neg_infinity | _], _), do: false

  def nan?([value | _], _)
      when is_binary(value) and value in ["Infinity", "+Infinity", "-Infinity"], do: false

  def nan?([val | _], _) do
    case Coercion.to_number(val) do
      :nan -> true
      :infinity -> false
      :neg_infinity -> false
      n when is_number(n) -> false
      _ -> true
    end
  end

  def nan?(_, _), do: true

  @doc "Returns whether a VM number is finite under JavaScript semantics."
  def finite?([n | _], _) when is_number(n), do: true
  def finite?([:infinity | _], _), do: false
  def finite?([:neg_infinity | _], _), do: false
  def finite?([:nan | _], _), do: false

  def finite?([val | _], _) do
    case Values.to_number(val) do
      n when is_number(n) -> true
      _ -> false
    end
  end

  def finite?(_, _), do: false
end
