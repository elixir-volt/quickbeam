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
      precision = ceil(53 * :math.log(2) / :math.log(radix))
      digits = frac_digits_list(frac_part, radix, precision + 3)
      digits = round_and_trim(digits, precision, radix, frac_part)
      chars = Enum.map(digits, &String.at("0123456789abcdefghijklmnopqrstuvwxyz", &1))
      sign <> int_str <> "." <> Enum.join(chars)
    end
  end

  defp frac_digits_list(_frac, _radix, 0), do: []

  defp frac_digits_list(frac, radix, remaining) do
    prod = frac * radix
    digit = trunc(prod)
    rest = prod - digit

    if rest == 0.0 do
      [digit]
    else
      [digit | frac_digits_list(rest, radix, remaining - 1)]
    end
  end

  defp round_and_trim(digits, precision, radix, original_frac) do
    truncated = Enum.take(digits, precision) |> trim_trailing_zeros()
    rounded = round_radix_digits(digits, precision, radix) |> trim_trailing_zeros()

    if truncated == rounded do
      truncated
    else
      trunc_rt = digits_to_float_precise(truncated, radix)
      round_rt = digits_to_float_precise(rounded, radix)

      trunc_exact = trunc_rt == original_frac
      round_exact = round_rt == original_frac

      cond do
        trunc_exact and not round_exact -> truncated
        round_exact and not trunc_exact -> rounded
        true ->
          trunc_err = abs(trunc_rt - original_frac)
          round_err = abs(round_rt - original_frac)
          if round_err < trunc_err, do: rounded, else: truncated
      end
    end
  end

  defp digits_to_float_precise(digits, radix) do
    {num, denom} =
      Enum.reduce(Enum.with_index(digits), {0, 1}, fn {d, i}, {n, _} ->
        power = round(:math.pow(radix, i + 1))
        {n * radix + d, power}
      end)

    num / denom
  end

  defp round_radix_digits(digits, precision, _radix) when length(digits) <= precision do
    digits
  end

  defp round_radix_digits(digits, precision, radix) do
    {keep, tail} = Enum.split(digits, precision)

    should_round_up =
      case tail do
        [d | _] when d >= div(radix, 2) + 1 -> true
        [d | rest] when d == div(radix, 2) ->
          Enum.any?(rest, &(&1 > 0))
        _ -> false
      end

    if should_round_up do
      propagate_carry(keep, radix)
    else
      keep
    end
  end

  defp propagate_carry(digits, radix) do
    {result, carry} =
      digits
      |> Enum.reverse()
      |> Enum.map_reduce(1, fn d, carry ->
        sum = d + carry
        {rem(sum, radix), div(sum, radix)}
      end)

    if carry > 0, do: [carry | result], else: result
  end

  defp trim_trailing_zeros(digits) do
    digits
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == 0))
    |> Enum.reverse()
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
    d = Runtime.to_int(digits)
    f = js_round_significant(abs(n * 1.0), d + 1)
    sign = if n < 0, do: "-", else: ""
    sign <> (:erlang.float_to_binary(f, [{:scientific, d}]) |> strip_exponent_zeros())
  end

  defp to_exponential(n, _), do: Runtime.stringify(n)

  defp strip_exponent_zeros(s) do
    case String.split(s, "e") do
      [mantissa, exp_str] -> mantissa <> "e" <> format_exponent(String.to_integer(exp_str))
      _ -> s
    end
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
    exp = trunc(:math.floor(:math.log10(abs(f))))
    sign = if f < 0, do: "-", else: ""
    f = js_round_significant(abs(f), p)

    if exp >= p or exp < -6 do
      sci = :erlang.float_to_binary(f, [{:scientific, p - 1}])

      case String.split(sci, "e") do
        [mantissa, exp_str] ->
          sign <> mantissa <> "e" <> format_exponent(String.to_integer(exp_str))

        _ ->
          Runtime.stringify(f)
      end
    else
      sign <> :erlang.float_to_binary(f, decimals: p - exp - 1)
    end
  end

  defp js_round_significant(f, p) do
    if f == 0.0, do: 0.0, else: do_js_round_sig(f, p)
  end

  defp do_js_round_sig(f, p) do
    exp = :math.floor(:math.log10(f))
    factor = :math.pow(10, p - 1 - exp)
    scaled = f * factor
    rounded = :erlang.trunc(scaled + 0.5)
    rounded / factor
  end

  defp format_exponent(exp) when exp >= 0, do: "+" <> Integer.to_string(exp)
  defp format_exponent(exp), do: Integer.to_string(exp)
end
