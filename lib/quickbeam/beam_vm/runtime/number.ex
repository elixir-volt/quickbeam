defmodule QuickBEAM.BeamVM.Runtime.Number do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime

  # ── Number.prototype ──

  def proto_property("toString"),
    do: {:builtin, "toString", fn args, this -> number_to_string(this, args) end}

  def proto_property("toFixed"),
    do: {:builtin, "toFixed", fn args, this -> number_to_fixed(this, args) end}

  def proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}

  def proto_property("toExponential"),
    do: {:builtin, "toExponential", fn args, this -> number_to_exponential(this, args) end}

  def proto_property("toPrecision"),
    do: {:builtin, "toPrecision", fn args, this -> number_to_precision(this, args) end}

  def proto_property(_), do: :undefined

  # ── Number static ──

  def static_property("isNaN"), do: {:builtin, "isNaN", fn [a | _] -> a == :nan end}

  def static_property("isFinite"),
    do:
      {:builtin, "isFinite",
       fn [a | _] -> a != :nan and a != :infinity and a != :neg_infinity end}

  def static_property("isInteger"),
    do:
      {:builtin, "isInteger",
       fn [a | _] -> is_integer(a) or (is_float(a) and a == Float.floor(a)) end}

  def static_property("parseInt"),
    do: {:builtin, "parseInt", fn args -> QuickBEAM.BeamVM.Runtime.Globals.parse_int(args) end}

  def static_property("parseFloat"),
    do:
      {:builtin, "parseFloat", fn args -> QuickBEAM.BeamVM.Runtime.Globals.parse_float(args) end}

  def static_property("NaN"), do: :nan
  def static_property("POSITIVE_INFINITY"), do: :infinity
  def static_property("NEGATIVE_INFINITY"), do: :neg_infinity
  def static_property("MAX_SAFE_INTEGER"), do: 9_007_199_254_740_991
  def static_property("MIN_SAFE_INTEGER"), do: -9_007_199_254_740_991
  def static_property(_), do: :undefined

  defp number_to_string(n, [radix | _]) when is_number(n) do
    r = Runtime.to_int(radix)

    cond do
      r == 10 ->
        QuickBEAM.BeamVM.Interpreter.Values.to_js_string(n * 1.0)

      r >= 2 and r <= 36 and n == trunc(n) ->
        Integer.to_string(trunc(n), r) |> String.downcase()

      r >= 2 and r <= 36 ->
        float_to_radix(n * 1.0, r)

      true ->
        Runtime.js_to_string(n)
    end
  end

  defp number_to_string(n, _), do: Runtime.js_to_string(n)

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

  defp number_to_fixed(n, _), do: Runtime.js_to_string(n)

  defp number_to_exponential(n, [digits | _]) when is_number(n) do
    d = Runtime.to_int(digits)
    f = n * 1.0
    exp = if f == 0.0, do: 0, else: trunc(:math.floor(:math.log10(abs(f))))
    mantissa = f / :math.pow(10, exp)
    sign = if exp >= 0, do: "+", else: ""
    :erlang.float_to_binary(mantissa, decimals: d) <> "e" <> sign <> Integer.to_string(exp)
  end

  defp number_to_exponential(n, _), do: Runtime.js_to_string(n)

  defp number_to_precision(n, [prec | _]) when is_number(n) do
    p = max(1, Runtime.to_int(prec))
    s = :erlang.float_to_binary(n * 1.0, [{:decimals, p + 10}, :compact])
    # Round to p significant digits
    {sign, abs_s} =
      if String.starts_with?(s, "-"), do: {"-", String.trim_leading(s, "-")}, else: {"", s}

    case Float.parse(abs_s) do
      {f, _} ->
        if f == 0.0 do
          sign <> "0" <> if(p > 1, do: "." <> String.duplicate("0", p - 1), else: "")
        else
          exp = :math.floor(:math.log10(abs(f)))
          rounded = Float.round(f / :math.pow(10, exp - p + 1)) * :math.pow(10, exp - p + 1)

          QuickBEAM.BeamVM.Interpreter.Values.to_js_string(
            if sign == "-", do: -rounded, else: rounded
          )
        end

      _ ->
        Runtime.js_to_string(n)
    end
  end

  defp number_to_precision(n, _), do: Runtime.js_to_string(n)
end
