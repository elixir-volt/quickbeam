defmodule QuickBEAM.BeamVM.Runtime.Number do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Runtime

  # ── Number.prototype ──

  proto "toString" do
    number_to_string(this, args)
  end

  proto "toFixed" do
    number_to_fixed(this, args)
  end

  proto "valueOf" do
    this
  end

  proto "toExponential" do
    number_to_exponential(this, args)
  end

  proto "toPrecision" do
    number_to_precision(this, args)
  end

  # ── Number static ──

  static "isNaN" do
    hd(args) == :nan
  end

  static "isFinite" do
    hd(args) not in [:nan, :infinity, :neg_infinity]
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

  # ── Formatting implementations ──

  defp number_to_string(n, [radix | _]) when is_number(n) do
    r = Runtime.to_int(radix)

    cond do
      r == 10 ->
        QuickBEAM.BeamVM.Interpreter.Values.stringify(n * 1.0)

      r >= 2 and r <= 36 and n == trunc(n) ->
        Integer.to_string(trunc(n), r) |> String.downcase()

      r >= 2 and r <= 36 ->
        float_to_radix(n * 1.0, r)

      true ->
        Runtime.stringify(n)
    end
  end

  defp number_to_string(n, _), do: Runtime.stringify(n)

  defp float_to_radix(n, radix) do
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    {sign, n} = if n < 0, do: {"-", -n}, else: {"", n}
    int_part = trunc(n)
    frac_part = n - int_part

    int_str = if int_part == 0, do: "0", else: integer_to_radix(int_part, radix, digits, "")

    frac_str =
      if frac_part == 0.0 do
        ""
      else
        build_frac(frac_part, radix, digits, "", 0)
      end

    if frac_str == "", do: sign <> int_str, else: sign <> int_str <> "." <> frac_str
  end

  defp integer_to_radix(0, _radix, _digits, acc), do: acc

  defp integer_to_radix(n, radix, digits, acc) do
    integer_to_radix(
      div(n, radix),
      radix,
      digits,
      <<String.at(digits, rem(n, radix))::binary, acc::binary>>
    )
  end

  defp build_frac(_frac, _radix, _digits, acc, count) when count >= 20, do: acc

  defp build_frac(frac, radix, digits, acc, count) do
    prod = frac * radix
    digit = trunc(prod)
    rest = prod - digit
    new_acc = acc <> String.at(digits, digit)

    if rest == 0.0 or count >= 19,
      do: new_acc,
      else: build_frac(rest, radix, digits, new_acc, count + 1)
  end

  defp number_to_fixed(:nan, _), do: "NaN"
  defp number_to_fixed(:infinity, _), do: "Infinity"
  defp number_to_fixed(:neg_infinity, _), do: "-Infinity"

  defp number_to_fixed(n, [digits | _]) when is_number(n) do
    d = max(0, Runtime.to_int(digits))
    s = :erlang.float_to_binary(n * 1.0, decimals: d)

    if d > 0 do
      s
    else
      String.trim_trailing(s, ".0")
    end
  end

  defp number_to_fixed(n, _), do: Runtime.stringify(n)

  defp number_to_exponential(n, [digits | _]) when is_number(n) do
    d = Runtime.to_int(digits)
    f = n * 1.0
    exp = if f == 0.0, do: 0, else: trunc(:math.floor(:math.log10(abs(f))))
    mantissa = f / :math.pow(10, exp)
    sign = if exp >= 0, do: "+", else: ""
    :erlang.float_to_binary(mantissa, decimals: d) <> "e" <> sign <> Integer.to_string(exp)
  end

  defp number_to_exponential(n, _), do: Runtime.stringify(n)

  defp number_to_precision(n, [prec | _]) when is_number(n) do
    p = max(1, Runtime.to_int(prec))
    s = :erlang.float_to_binary(n * 1.0, [{:decimals, p + 10}, :compact])

    {sign, abs_s} =
      if String.starts_with?(s, "-"), do: {"-", String.trim_leading(s, "-")}, else: {"", s}

    case Float.parse(abs_s) do
      {f, _} ->
        if f == 0.0 do
          sign <> "0" <> if(p > 1, do: "." <> String.duplicate("0", p - 1), else: "")
        else
          exp = :math.floor(:math.log10(abs(f)))
          rounded = Float.round(f / :math.pow(10, exp - p + 1)) * :math.pow(10, exp - p + 1)

          QuickBEAM.BeamVM.Interpreter.Values.stringify(
            if sign == "-", do: -rounded, else: rounded
          )
        end

      _ ->
        Runtime.stringify(n)
    end
  end

  defp number_to_precision(n, _), do: Runtime.stringify(n)
end
