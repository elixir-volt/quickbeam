defmodule QuickBEAM.BeamVM.Runtime.Number do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Runtime

  # ── Number.prototype ──

  proto "toString" do
    to_string_with_radix(this, args)
  end

  proto "toFixed" do
    to_fixed(this, args)
  end

  proto "valueOf" do
    this
  end

  proto "toExponential" do
    to_exponential(this, args)
  end

  proto "toPrecision" do
    to_precision(this, args)
  end

  # ── Number static ──

  static "isNaN" do
    hd(args) == :nan
  end

  static "isFinite" do
    is_number(hd(args))
  end

  static "isInteger" do
    is_integer(hd(args)) or (is_float(hd(args)) and hd(args) == Float.floor(hd(args)))
  end

  static "parseInt" do
    Runtime.Globals.parse_int(args)
  end

  static "parseFloat" do
    Runtime.Globals.parse_float(args)
  end

  static_val("NaN", :nan)
  static_val("POSITIVE_INFINITY", :infinity)
  static_val("NEGATIVE_INFINITY", :neg_infinity)
  static_val("MAX_SAFE_INTEGER", 9_007_199_254_740_991)
  static_val("MIN_SAFE_INTEGER", -9_007_199_254_740_991)
  static_val("EPSILON", 2.220446049250313e-16)
  static_val("MIN_VALUE", 5.0e-324)

  # ── toString(radix) ──

  defp to_string_with_radix(n, [radix | _]) when is_number(n) do
    r = Runtime.to_int(radix)

    cond do
      r == 10 ->
        Runtime.stringify(n)

      r >= 2 and r <= 36 and n == trunc(n) ->
        Integer.to_string(trunc(n), r) |> String.downcase()

      r >= 2 and r <= 36 ->
        float_to_radix(n * 1.0, r)

      true ->
        Runtime.stringify(n)
    end
  end

  defp to_string_with_radix(n, _), do: Runtime.stringify(n)

  defp float_to_radix(n, radix) do
    {sign, n} = if n < 0, do: {"-", -n}, else: {"", n}
    int_part = trunc(n)
    frac_part = n - int_part

    int_str =
      if int_part == 0, do: "0", else: Integer.to_string(int_part, radix) |> String.downcase()

    if frac_part == 0.0 do
      sign <> int_str
    else
      sign <> int_str <> "." <> frac_digits(frac_part, radix, 20)
    end
  end

  defp frac_digits(_frac, _radix, 0), do: ""

  defp frac_digits(frac, radix, remaining) do
    prod = frac * radix
    digit = trunc(prod)
    rest = prod - digit
    char = String.at("0123456789abcdefghijklmnopqrstuvwxyz", digit)

    if rest == 0.0, do: char, else: char <> frac_digits(rest, radix, remaining - 1)
  end

  # ── toFixed(digits) ──

  defp to_fixed(:nan, _), do: "NaN"
  defp to_fixed(:infinity, _), do: "Infinity"
  defp to_fixed(:neg_infinity, _), do: "-Infinity"

  defp to_fixed(n, [digits | _]) when is_number(n) do
    :erlang.float_to_binary(n * 1.0, decimals: max(0, Runtime.to_int(digits)))
  end

  defp to_fixed(n, _), do: Runtime.stringify(n)

  # ── toExponential(digits) ──

  defp to_exponential(n, [digits | _]) when is_number(n) do
    :erlang.float_to_binary(n * 1.0, [{:scientific, Runtime.to_int(digits)}])
    |> strip_exponent_zeros()
  end

  defp to_exponential(n, _), do: Runtime.stringify(n)

  defp strip_exponent_zeros(s) do
    String.replace(s, ~r/e([+-])0*(\d+)/, "e\\1\\2")
  end

  # ── toPrecision(precision) ──

  defp to_precision(n, [prec | _]) when is_number(n) do
    p = max(1, Runtime.to_int(prec))
    f = n * 1.0

    if f == 0.0 do
      zero_precision(n < 0, p)
    else
      format_precision(f, p)
    end
  end

  defp to_precision(n, _), do: Runtime.stringify(n)

  defp zero_precision(negative?, p) do
    prefix = if negative?, do: "-", else: ""
    prefix <> "0" <> if(p > 1, do: "." <> String.duplicate("0", p - 1), else: "")
  end

  defp format_precision(f, p) do
    sci = :erlang.float_to_binary(abs(f), [{:scientific, p - 1}])

    case String.split(sci, "e") do
      [mantissa, exp_str] ->
        exp = String.to_integer(exp_str)
        sign = if f < 0, do: "-", else: ""

        if exp >= 0 and exp < p do
          sign <> shift_decimal(mantissa, exp)
        else
          sign <> mantissa <> "e" <> format_exponent(exp)
        end

      _ ->
        Runtime.stringify(f)
    end
  end

  defp shift_decimal(mantissa, exp) do
    digits = String.replace(mantissa, ".", "")
    point = exp + 1

    if point >= String.length(digits) do
      digits
    else
      String.slice(digits, 0, point) <> "." <> String.slice(digits, point..-1//1)
    end
  end

  defp format_exponent(exp) when exp >= 0, do: "+" <> Integer.to_string(exp)
  defp format_exponent(exp), do: Integer.to_string(exp)
end
