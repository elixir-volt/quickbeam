defmodule QuickBEAM.VM.Runtime.Number do
  @moduledoc "JS `Number` built-in: prototype methods (`toFixed`, `toString`, etc.) and static properties (`MAX_SAFE_INTEGER`, etc.)."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{JSThrow, Runtime, RuntimeState}
  alias QuickBEAM.VM.Runtime.Globals.Numeric

  defintrinsic "Number" do
    constructor(&QuickBEAM.VM.Runtime.ConstructorCallbacks.number/2,
      length: 1,
      phase: :fundamental
    )

    prototype extends: :object do
      slot(:NumberData, 0)

      method "toString", length: 1, receiver: :number do
        to_string_with_radix(this, args)
      end

      method "toFixed", length: 1, receiver: :number do
        to_fixed(this, args)
      end

      method "valueOf", receiver: :number do
        this
      end

      method "toExponential", length: 1, receiver: :number do
        to_exponential(this, args)
      end

      method "toPrecision", length: 1, receiver: :number do
        to_precision(this, args)
      end

      method "toLocaleString", receiver: :number do
        to_string_with_radix(this, [])
      end
    end
  end

  # ── Number statics ──

  static "isSafeInteger", length: 1 do
    val = arg(args, 0, :undefined)
    is_number(val) and val == trunc(val * 1.0) and abs(val) <= 9_007_199_254_740_991
  end

  # ── Number static ──

  static "isNaN" do
    arg(args, 0, :undefined) == :nan
  end

  static "isFinite" do
    is_number(arg(args, 0, :undefined))
  end

  static "isInteger" do
    val = arg(args, 0, :undefined)
    is_integer(val) or (is_float(val) and val == Float.floor(val))
  end

  static_val("parseInt", {:builtin, "parseInt", &Numeric.parse_int/2})
  static_val("parseFloat", {:builtin, "parseFloat", &Numeric.parse_float/2})

  constant("NaN", :nan)
  constant("POSITIVE_INFINITY", :infinity)
  constant("NEGATIVE_INFINITY", :neg_infinity)
  constant("MAX_SAFE_INTEGER", 9_007_199_254_740_991)
  constant("MIN_SAFE_INTEGER", -9_007_199_254_740_991)
  constant("EPSILON", 2.220446049250313e-16)
  # credo:disable-for-next-line Credo.Check.Readability.LargeNumbers
  constant("MAX_VALUE", 1.7976931348623157e+308)
  constant("MIN_VALUE", 5.0e-324)

  # ── toString(radix) ──

  defp to_string_with_radix(n, [:undefined | _])
       when is_number(n) or n in [:nan, :infinity, :neg_infinity],
       do: Runtime.stringify(n)

  defp to_string_with_radix(n, [radix | _])
       when is_number(n) or n in [:nan, :infinity, :neg_infinity] do
    r = to_integer_or_throw(radix)

    cond do
      r < 2 or r > 36 ->
        JSThrow.range_error!("radix out of range")

      n in [:nan, :infinity, :neg_infinity] or r == 10 ->
        Runtime.stringify(n)

      n == trunc(n) ->
        Integer.to_string(trunc(n), r) |> String.downcase()

      true ->
        format_float_with_runtime(n * 1.0, r) || float_to_radix(n * 1.0, r)
    end
  end

  defp to_string_with_radix(n, _), do: Runtime.stringify(n)

  defp format_float_with_runtime(n, radix) do
    case RuntimeState.current() do
      %{runtime_pid: runtime_pid} when runtime_pid != nil ->
        literal = :erlang.float_to_binary(n, [:short])

        case QuickBEAM.Runtime.eval(runtime_pid, "(#{literal}).toString(#{radix})") do
          {:ok, value} when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

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
        trunc_exact and not round_exact ->
          truncated

        round_exact and not trunc_exact ->
          rounded

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
        [d | _] when d >= div(radix, 2) + 1 ->
          true

        [d | rest] when d == div(radix, 2) ->
          Enum.any?(rest, &(&1 > 0)) or rem(List.last(keep, 0), 2) == 1

        _ ->
          false
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

  defp to_fixed(n, [digits | _]) when n in [:nan, :infinity, :neg_infinity] do
    d = to_integer_or_throw(digits)
    if d < 0 or d > 100, do: JSThrow.range_error!("fractionDigits out of range")
    Runtime.stringify(n)
  end

  defp to_fixed(:nan, _), do: "NaN"
  defp to_fixed(:infinity, _), do: "Infinity"
  defp to_fixed(:neg_infinity, _), do: "-Infinity"

  defp to_fixed(n, [digits | _]) when is_number(n) and abs(n) >= 1.0e21 do
    d = to_integer_or_throw(digits)
    if d < 0 or d > 100, do: JSThrow.range_error!("fractionDigits out of range")
    Runtime.stringify(n)
  end

  defp to_fixed(n, _args) when is_number(n) and abs(n) >= 1.0e21, do: Runtime.stringify(n)

  defp to_fixed(n, [digits | _]) when is_number(n) do
    d = to_integer_or_throw(digits)
    if d < 0 or d > 100, do: JSThrow.range_error!("fractionDigits out of range")
    :erlang.float_to_binary(n * 1.0, decimals: d)
  end

  defp to_fixed(n, _), do: Runtime.stringify(n)

  # ── toExponential(digits) ──

  defp to_exponential(n, [digits | _]) when n in [:nan, :infinity, :neg_infinity] do
    to_integer_or_throw(digits)
    Runtime.stringify(n)
  end

  defp to_exponential(n, [:undefined | _]) when is_number(n), do: default_exponential(n)

  defp to_exponential(n, [digits | _]) when is_number(n) do
    d = to_integer_or_throw(digits)
    if d < 0 or d > 100, do: JSThrow.range_error!("fractionDigits out of range")
    f = js_round_significant(abs(n * 1.0), d + 1)
    sign = if n < 0, do: "-", else: ""
    sign <> (:erlang.float_to_binary(f, [{:scientific, d}]) |> strip_exponent_zeros())
  end

  defp to_exponential(n, _) when is_number(n), do: default_exponential(n)
  defp to_exponential(n, _), do: Runtime.stringify(n)

  defp default_exponential(0), do: "0e+0"

  defp default_exponential(n) do
    sign = if n < 0, do: "-", else: ""
    s = Runtime.stringify(abs(n * 1.0))

    if String.contains?(s, "e") do
      sign <> strip_exponent_zeros(s)
    else
      [int, frac] = (String.split(s, ".") ++ [""]) |> Enum.take(2)
      [head | int_tail] = String.graphemes(int)
      mantissa_tail = (Enum.join(int_tail) <> frac) |> String.trim_trailing("0")
      mantissa = head <> if(mantissa_tail == "", do: "", else: "." <> mantissa_tail)
      sign <> mantissa <> "e+" <> Integer.to_string(String.length(int) - 1)
    end
  end

  defp strip_exponent_zeros(s) do
    case String.split(s, "e") do
      [mantissa, exp_str] -> mantissa <> "e" <> format_exponent(String.to_integer(exp_str))
      _ -> s
    end
  end

  # ── toPrecision(precision) ──

  defp to_precision(n, [:undefined | _]) when is_number(n) or n == :nan, do: Runtime.stringify(n)

  defp to_precision(:nan, [prec | _]) do
    to_integer_or_throw(prec)
    "NaN"
  end

  defp to_precision(n, [prec | _]) when is_number(n) do
    p = to_integer_or_throw(prec)
    if p < 1 or p > 100, do: JSThrow.range_error!("precision out of range")
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
    format_precision_with_runtime(f, p) || do_format_precision(f, p)
  end

  defp format_precision_with_runtime(n, precision) do
    case RuntimeState.current() do
      %{runtime_pid: runtime_pid} when runtime_pid != nil ->
        literal = :erlang.float_to_binary(n * 1.0, [:short])

        case QuickBEAM.Runtime.eval(runtime_pid, "(#{literal}).toPrecision(#{precision})") do
          {:ok, value} when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp do_format_precision(f, p) do
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

  defp to_integer_or_throw({:bigint, _}),
    do: JSThrow.type_error!("Cannot convert BigInt to number")

  defp to_integer_or_throw(:infinity), do: 101
  defp to_integer_or_throw(:neg_infinity), do: -1

  defp to_integer_or_throw(value), do: Runtime.to_int(value)

  defp format_exponent(exp) when exp >= 0, do: "+" <> Integer.to_string(exp)
  defp format_exponent(exp), do: Integer.to_string(exp)
end
