defmodule QuickBEAM.VM.Runtime.Math do
  @moduledoc "JS `Math` object: all standard methods (`floor`, `ceil`, `sin`, `random`, etc.) and numeric constants."

  use QuickBEAM.VM.Builtin

  import Bitwise

  alias QuickBEAM.VM.{Builtin, Heap, Invocation}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Semantics.Iterators

  @method_lengths %{
    "abs" => 1,
    "acos" => 1,
    "acosh" => 1,
    "asin" => 1,
    "asinh" => 1,
    "atan" => 1,
    "atan2" => 2,
    "atanh" => 1,
    "cbrt" => 1,
    "ceil" => 1,
    "clz32" => 1,
    "cos" => 1,
    "cosh" => 1,
    "exp" => 1,
    "expm1" => 1,
    "floor" => 1,
    "f16round" => 1,
    "fround" => 1,
    "hypot" => 2,
    "imul" => 2,
    "log" => 1,
    "log10" => 1,
    "log1p" => 1,
    "log2" => 1,
    "max" => 2,
    "min" => 2,
    "pow" => 2,
    "random" => 0,
    "round" => 1,
    "sign" => 1,
    "sin" => 1,
    "sinh" => 1,
    "sqrt" => 1,
    "sumPrecise" => 1,
    "tan" => 1,
    "tanh" => 1,
    "trunc" => 1
  }

  @constants ~w(E LN10 LN2 LOG10E LOG2E PI SQRT1_2 SQRT2 MAX_SAFE_INTEGER MIN_SAFE_INTEGER)

  def install_metadata({:builtin, _name, map} = math) when is_map(map) do
    Builtin.install_object_metadata(math, @method_lengths,
      constants: @constants,
      to_string_tag: "Math"
    )
  end

  js_object "Math" do
    @ecma "21.3.2.16"
    method "floor" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n when n == 0 -> n
        n -> floor(n)
      end
    end

    @ecma "21.3.2.10"
    method "ceil" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n when n == 0 -> n
        n when n > -1 and n < 0 -> -0.0
        n -> ceil(n)
      end
    end

    @ecma "21.3.2.29"
    method "round" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n when n == 0 -> n
        n when n >= -0.5 and n < 0 -> -0.0
        n when n > 0 and n < 0.5 -> 0
        n when abs(n) >= 4_503_599_627_370_496.0 -> n
        n -> floor(n + 0.5)
      end
    end

    @ecma "21.3.2.1"
    method "abs" do
      case QuickBEAM.VM.Builtin.arg(args, 0, :undefined) do
        {:bigint, _} ->
          QuickBEAM.VM.JSThrow.type_error!("Cannot convert a BigInt value to a number")

        value ->
          case Runtime.to_number(value) do
            :infinity -> :infinity
            :neg_infinity -> :infinity
            :nan -> :nan
            n when n == 0 -> 0
            n -> abs(n)
          end
      end
    end

    @ecma "21.3.2.25"
    method "max" do
      extremum(args, :max)
    end

    @ecma "21.3.2.26"
    method "min" do
      extremum(args, :min)
    end

    @ecma "21.3.2.33"
    method "sqrt" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :nan
        :nan -> :nan
        n when n < 0 -> :nan
        n -> :math.sqrt(n)
      end
    end

    @ecma "21.3.2.27"
    method "pow" do
      [a, b | _] = args
      math_pow(Runtime.to_float(a), Runtime.to_float(b))
    end

    @ecma "21.3.2.28"
    method "random" do
      :rand.uniform()
    end

    @ecma "21.3.2.36"
    method "trunc" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n when n == 0 -> n
        n when n > -1 and n < 0 -> -0.0
        n -> trunc(n)
      end
    end

    @ecma "21.3.2.30"
    method "sign" do
      case Runtime.to_number(hd(args)) do
        :infinity -> 1
        :neg_infinity -> -1
        :nan -> :nan
        n when n > 0 -> 1
        n when n < 0 -> -1
        n -> n
      end
    end

    @ecma "21.3.2.21"
    method "log" do
      math_log(Runtime.to_number(hd(args)), &:math.log/1)
    end

    @ecma "21.3.2.24"
    method "log2" do
      math_log(Runtime.to_number(hd(args)), &:math.log2/1)
    end

    @ecma "21.3.2.23"
    method "log10" do
      math_log(Runtime.to_number(hd(args)), &:math.log10/1)
    end

    @ecma "21.3.2.31"
    method "sin" do
      trig(Runtime.to_float(hd(args)), &:math.sin/1)
    end

    @ecma "21.3.2.12"
    method "cos" do
      trig(Runtime.to_float(hd(args)), &:math.cos/1)
    end

    @ecma "21.3.2.34"
    method "tan" do
      trig(Runtime.to_float(hd(args)), &:math.tan/1)
    end

    @ecma "21.3.2.11"
    method "clz32" do
      n = Values.to_uint32(hd(args))
      if n == 0, do: 32, else: 31 - trunc(:math.log2(n))
    end

    @ecma "21.3.2.18"
    method "f16round" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        f -> f16round(f)
      end
    end

    @ecma "21.3.2.17"
    method "fround" do
      case Runtime.to_float(hd(args)) do
        :infinity ->
          :infinity

        :neg_infinity ->
          :neg_infinity

        :nan ->
          :nan

        f ->
          <<f32::float-32>> = <<f::float-32>>
          f32 * 1.0
      end
    end

    @ecma "21.3.2.20"
    method "imul" do
      [a, b | _] = args

      Values.to_int32(
        Values.to_int32(a) *
          Values.to_int32(b)
      )
    end

    @ecma "21.3.2.8"
    method "atan2" do
      [a, b | _] = args
      math_atan2(Runtime.to_float(a), Runtime.to_float(b))
    end

    @ecma "21.3.2.4"
    method "asin" do
      inverse_unit(Runtime.to_float(hd(args)), &:math.asin/1)
    end

    @ecma "21.3.2.2"
    method "acos" do
      inverse_unit(Runtime.to_float(hd(args)), &:math.acos/1)
    end

    @ecma "21.3.2.6"
    method "atan" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :math.pi() / 2
        :neg_infinity -> -:math.pi() / 2
        :nan -> :nan
        n -> :math.atan(n)
      end
    end

    @ecma "21.3.2.14"
    method "exp" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> 0
        :nan -> :nan
        n -> :math.exp(n)
      end
    end

    @ecma "21.3.2.9"
    method "cbrt" do
      case Runtime.to_number(hd(args)) do
        :infinity ->
          :infinity

        :neg_infinity ->
          :neg_infinity

        :nan ->
          :nan

        f when f == 0 ->
          f

        f ->
          sign = if f < 0, do: -1, else: 1
          sign * :math.pow(abs(f), 1.0 / 3.0)
      end
    end

    @ecma "21.3.2.22"
    method "log1p" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :nan
        :nan -> :nan
        n when n == 0 -> n
        n -> math_log(1 + n, &:math.log/1)
      end
    end

    @ecma "21.3.2.15"
    method "expm1" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> -1
        :nan -> :nan
        n when n == 0 -> n
        n -> :math.exp(n) - 1
      end
    end

    @ecma "21.3.2.13"
    method "cosh" do
      hyperbolic(Runtime.to_float(hd(args)), &:math.cosh/1)
    end

    @ecma "21.3.2.32"
    method "sinh" do
      signed_hyperbolic(Runtime.to_float(hd(args)), &:math.sinh/1)
    end

    @ecma "21.3.2.35"
    method "tanh" do
      case Runtime.to_float(hd(args)) do
        :infinity -> 1
        :neg_infinity -> -1
        :nan -> :nan
        n -> :math.tanh(n)
      end
    end

    @ecma "21.3.2.3"
    method "acosh" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :nan
        :nan -> :nan
        n when n < 1 -> :nan
        n -> :math.acosh(n)
      end
    end

    @ecma "21.3.2.5"
    method "asinh" do
      signed_hyperbolic(Runtime.to_float(hd(args)), &:math.asinh/1)
    end

    @ecma "21.3.2.7"
    method "atanh" do
      case Runtime.to_float(hd(args)) do
        :nan -> :nan
        n when n == 1 -> :infinity
        n when n == -1 -> :neg_infinity
        n when n < -1 or n > 1 -> :nan
        n -> :math.atanh(n)
      end
    end

    @ecma "21.3.2.33"
    method "sumPrecise" do
      case args do
        [iterable | _] -> iterable |> sum_precise_values() |> shewchuk_sum()
        [] -> QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires an iterable")
      end
    end

    @ecma "21.3.2.19"
    method "hypot" do
      values = Enum.map(args, &Runtime.to_float/1)

      cond do
        Enum.any?(values, &(&1 in [:infinity, :neg_infinity])) ->
          :infinity

        Enum.any?(values, &(&1 == :nan)) ->
          :nan

        true ->
          sum = Enum.reduce(values, 0.0, fn a, acc -> acc + :math.pow(a, 2) end)
          :math.sqrt(sum)
      end
    end

    val("PI", :math.pi())
    val("E", :math.exp(1))
    val("LN2", :math.log(2))
    val("LN10", :math.log(10))
    val("LOG2E", :math.log2(:math.exp(1)))
    val("LOG10E", :math.log10(:math.exp(1)))
    val("SQRT2", :math.sqrt(2))
    val("SQRT1_2", :math.sqrt(2) / 2)
    val("MAX_SAFE_INTEGER", 9_007_199_254_740_991)
    val("MIN_SAFE_INTEGER", -9_007_199_254_740_991)
  end

  defp extremum([], :max), do: :neg_infinity
  defp extremum([], :min), do: :infinity

  defp extremum(args, kind) do
    args
    |> Enum.map(&Runtime.to_number/1)
    |> Enum.reduce(extremum_initial(kind), fn
      :nan, _acc -> :nan
      _value, :nan -> :nan
      value, acc -> extremum_value(kind, value, acc)
    end)
  end

  defp extremum_initial(:max), do: :neg_infinity
  defp extremum_initial(:min), do: :infinity

  defp extremum_value(:max, :infinity, _acc), do: :infinity
  defp extremum_value(:max, :neg_infinity, acc), do: acc
  defp extremum_value(:max, _value, :infinity), do: :infinity
  defp extremum_value(:max, value, :neg_infinity), do: value

  defp extremum_value(:max, value, acc) when value == 0 and acc == 0,
    do: if(Values.neg_zero?(acc), do: value, else: acc)

  defp extremum_value(:max, value, acc) when value > acc, do: value
  defp extremum_value(:max, _value, acc), do: acc

  defp extremum_value(:min, :neg_infinity, _acc), do: :neg_infinity
  defp extremum_value(:min, :infinity, acc), do: acc
  defp extremum_value(:min, _value, :neg_infinity), do: :neg_infinity
  defp extremum_value(:min, value, :infinity), do: value

  defp extremum_value(:min, value, acc) when value == 0 and acc == 0,
    do: if(Values.neg_zero?(value), do: value, else: acc)

  defp extremum_value(:min, value, acc) when value < acc, do: value
  defp extremum_value(:min, _value, acc), do: acc

  defp f16round(value) when value == 0, do: value

  defp f16round(value) do
    sign = if value < 0 or Values.neg_zero?(value), do: -1, else: 1
    abs_value = abs(value)

    cond do
      abs_value >= 65_520 ->
        if sign < 0, do: :neg_infinity, else: :infinity

      abs_value < :math.pow(2, -14) ->
        rounded = round_ties_even(abs_value / :math.pow(2, -24)) * :math.pow(2, -24)
        signed_value(sign, rounded)

      true ->
        exponent = floor(:math.log2(abs_value))
        fraction = round_ties_even((abs_value / :math.pow(2, exponent) - 1) * 1024)

        {exponent, fraction} =
          if fraction == 1024, do: {exponent + 1, 0}, else: {exponent, fraction}

        rounded = (1 + fraction / 1024) * :math.pow(2, exponent)
        signed_value(sign, rounded)
    end
  end

  defp signed_value(sign, value) when value == 0, do: if(sign < 0, do: -0.0, else: 0)
  defp signed_value(sign, value), do: sign * value

  defp round_ties_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  defp inverse_unit(:nan, _fun), do: :nan
  defp inverse_unit(:infinity, _fun), do: :nan
  defp inverse_unit(:neg_infinity, _fun), do: :nan
  defp inverse_unit(n, _fun) when n < -1 or n > 1, do: :nan
  defp inverse_unit(n, fun), do: fun.(n)

  defp trig(value, fun) do
    case value do
      :nan -> :nan
      :infinity -> :nan
      :neg_infinity -> :nan
      n -> fun.(n)
    end
  end

  defp hyperbolic(value, fun) do
    case value do
      :nan -> :nan
      :infinity -> :infinity
      :neg_infinity -> :infinity
      n -> fun.(n)
    end
  end

  defp signed_hyperbolic(value, fun) do
    case value do
      :nan -> :nan
      :infinity -> :infinity
      :neg_infinity -> :neg_infinity
      n -> fun.(n)
    end
  end

  defp math_log(:nan, _fun), do: :nan
  defp math_log(:infinity, _fun), do: :infinity
  defp math_log(:neg_infinity, _fun), do: :nan
  defp math_log(n, _fun) when n < 0, do: :nan
  defp math_log(n, _fun) when n == 0, do: :neg_infinity
  defp math_log(n, fun), do: fun.(n)

  defp math_atan2(:nan, _), do: :nan
  defp math_atan2(_, :nan), do: :nan
  defp math_atan2(:infinity, :infinity), do: :math.pi() / 4
  defp math_atan2(:infinity, :neg_infinity), do: 3 * :math.pi() / 4
  defp math_atan2(:neg_infinity, :infinity), do: -:math.pi() / 4
  defp math_atan2(:neg_infinity, :neg_infinity), do: -3 * :math.pi() / 4
  defp math_atan2(:infinity, _), do: :math.pi() / 2
  defp math_atan2(:neg_infinity, _), do: -:math.pi() / 2
  defp math_atan2(y, :infinity) when is_number(y) and y < 0, do: -0.0
  defp math_atan2(y, :infinity) when is_number(y), do: if(Values.neg_zero?(y), do: -0.0, else: 0)
  defp math_atan2(y, :neg_infinity) when is_number(y) and y >= 0, do: :math.pi()
  defp math_atan2(_, :neg_infinity), do: -:math.pi()

  defp math_atan2(y, x) do
    if is_number(y) and is_number(x) and Values.neg_zero?(y) and x > 0,
      do: -0.0,
      else: :math.atan2(y, x)
  end

  defp math_pow(_base, exp) when exp == 0, do: 1
  defp math_pow(:nan, _exp), do: :nan
  defp math_pow(_base, :nan), do: :nan
  defp math_pow(:infinity, :infinity), do: :infinity
  defp math_pow(:infinity, :neg_infinity), do: 0
  defp math_pow(:infinity, exp) when is_number(exp) and exp > 0, do: :infinity
  defp math_pow(:infinity, exp) when is_number(exp) and exp < 0, do: 0

  defp math_pow(:neg_infinity, :infinity), do: :infinity
  defp math_pow(:neg_infinity, :neg_infinity), do: 0

  defp math_pow(:neg_infinity, exp) when is_number(exp) and exp > 0 do
    if odd_integer?(exp), do: :neg_infinity, else: :infinity
  end

  defp math_pow(:neg_infinity, exp) when is_number(exp) and exp < 0 do
    if odd_integer?(exp), do: -0.0, else: 0
  end

  defp math_pow(base, exp) when is_number(base) and base == 0 and is_number(exp) and exp < 0 do
    if Values.neg_zero?(base) and odd_integer?(exp), do: :neg_infinity, else: :infinity
  end

  defp math_pow(base, :infinity) when abs(base) > 1, do: :infinity
  defp math_pow(base, :infinity) when abs(base) < 1, do: 0
  defp math_pow(base, :infinity) when abs(base) == 1, do: :nan
  defp math_pow(base, :neg_infinity) when abs(base) > 1, do: 0
  defp math_pow(base, :neg_infinity) when abs(base) < 1, do: :infinity
  defp math_pow(base, :neg_infinity) when abs(base) == 1, do: :nan

  defp math_pow(base, exp) do
    try do
      :math.pow(base, exp)
    rescue
      ArithmeticError -> :nan
    end
  end

  defp odd_integer?(value),
    do:
      is_integer(value) or
        (is_float(value) and value == trunc(value) and rem(trunc(value), 2) != 0)

  defp sum_precise_values({:obj, ref} = iterable) do
    ensure_sum_iterable!(iterable, Heap.get_obj(ref, %{}))

    case Heap.get_array_prop(ref, {:symbol, "Symbol.iterator"}) do
      custom_iter when custom_iter not in [:undefined, nil] ->
        iter = Invocation.invoke_with_receiver(custom_iter, [], Runtime.gas_budget(), iterable)
        collect_sum_values(iter, Get.get(iter, "next"), [])

      _ ->
        {iter, next_fn} = Iterators.for_of_start(iterable)
        collect_sum_values(iter, next_fn, [])
    end
  end

  defp sum_precise_values({:qb_arr, arr}), do: :array.to_list(arr)
  defp sum_precise_values(list) when is_list(list), do: list

  defp sum_precise_values(_),
    do: QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires an iterable")

  defp ensure_sum_iterable!(_iterable, {:qb_arr, _}), do: :ok
  defp ensure_sum_iterable!(_iterable, list) when is_list(list), do: :ok

  defp ensure_sum_iterable!(iterable, map) when is_map(map) do
    sym_iter = {:symbol, "Symbol.iterator"}

    unless Get.get(iterable, sym_iter) |> QuickBEAM.VM.Builtin.callable?() or
             QuickBEAM.VM.Builtin.callable?(Get.get(iterable, "next")) do
      QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires an iterable")
    end
  end

  defp ensure_sum_iterable!(_iterable, _),
    do: QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires an iterable")

  defp collect_sum_values(iter, next_fn, acc) do
    case Iterators.for_of_next(next_fn, iter) do
      {true, _value, _new_iter} ->
        Enum.reverse(acc)

      {false, value, new_iter} ->
        unless sum_number?(value) do
          Iterators.iterator_close(new_iter)
          QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires numbers")
        end

        collect_sum_values(new_iter, next_fn, [value | acc])
    end
  end

  defp shewchuk_sum(list) do
    validate_sum_numbers!(list)

    cond do
      Enum.any?(list, &(&1 == :nan)) ->
        :nan

      Enum.any?(list, &(&1 == :infinity)) and Enum.any?(list, &(&1 == :neg_infinity)) ->
        :nan

      Enum.any?(list, &(&1 == :infinity)) ->
        :infinity

      Enum.any?(list, &(&1 == :neg_infinity)) ->
        :neg_infinity

      all_negative_zero?(list) ->
        -0.0

      true ->
        finite_sum(list)
    end
  end

  defp validate_sum_numbers!(list) do
    unless Enum.all?(list, &sum_number?/1) do
      QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires numbers")
    end
  end

  defp sum_number?(value), do: is_number(value) or value in [:nan, :infinity, :neg_infinity]

  defp all_negative_zero?([]), do: true
  defp all_negative_zero?(list), do: Enum.all?(list, &Values.neg_zero?/1)

  defp finite_sum(list) do
    list
    |> Enum.map(&Runtime.to_float/1)
    |> exact_binary_sum()
  end

  defp exact_binary_sum([]), do: 0.0

  defp exact_binary_sum(floats) do
    decoded = Enum.map(floats, &decode_finite_float/1)
    min_exp = decoded |> Enum.map(&elem(&1, 2)) |> Enum.min()

    total =
      Enum.reduce(decoded, 0, fn {sign, mantissa, exp}, acc ->
        acc + sign * (mantissa <<< (exp - min_exp))
      end)

    exact_integer_to_float(total, min_exp)
  end

  defp decode_finite_float(float) do
    <<sign_bit::1, exp_bits::11, fraction::52>> = <<float::float-64>>
    sign = if sign_bit == 1, do: -1, else: 1

    cond do
      exp_bits == 0 and fraction == 0 -> {sign, 0, 0}
      exp_bits == 0 -> {sign, fraction, -1074}
      true -> {sign, (1 <<< 52) + fraction, exp_bits - 1075}
    end
  end

  defp exact_integer_to_float(0, _exp), do: 0.0

  defp exact_integer_to_float(total, exp) do
    sign_bit = if total < 0, do: 1, else: 0
    magnitude = abs(total)
    bit_len = integer_bit_length(magnitude)
    unbiased = exp + bit_len - 1

    cond do
      unbiased > 1023 ->
        if sign_bit == 1, do: :neg_infinity, else: :infinity

      unbiased < -1022 ->
        subnormal_integer_to_float(sign_bit, magnitude, exp)

      bit_len <= 53 ->
        significand = magnitude <<< (53 - bit_len)
        pack_float(sign_bit, unbiased + 1023, significand - (1 <<< 52))

      true ->
        normal_rounded_integer_to_float(sign_bit, magnitude, bit_len, unbiased)
    end
  end

  defp normal_rounded_integer_to_float(sign_bit, magnitude, bit_len, unbiased) do
    significand = round_shift_right(magnitude, bit_len - 53)

    cond do
      significand == 1 <<< 53 and unbiased == 1023 ->
        if sign_bit == 1, do: :neg_infinity, else: :infinity

      significand == 1 <<< 53 ->
        pack_float(sign_bit, unbiased + 1024, 0)

      true ->
        pack_float(sign_bit, unbiased + 1023, significand - (1 <<< 52))
    end
  end

  defp subnormal_integer_to_float(sign_bit, magnitude, exp) do
    shift = -(exp + 1074)
    fraction = if shift <= 0, do: magnitude <<< -shift, else: round_shift_right(magnitude, shift)

    cond do
      fraction == 0 -> if sign_bit == 1, do: -0.0, else: 0.0
      fraction >= 1 <<< 52 -> pack_float(sign_bit, 1, fraction - (1 <<< 52))
      true -> pack_float(sign_bit, 0, fraction)
    end
  end

  defp round_shift_right(value, shift) when shift <= 0, do: value <<< -shift

  defp round_shift_right(value, shift) do
    quotient = value >>> shift
    remainder = value - (quotient <<< shift)
    halfway = 1 <<< (shift - 1)

    if remainder > halfway or (remainder == halfway and (quotient &&& 1) == 1),
      do: quotient + 1,
      else: quotient
  end

  defp pack_float(sign_bit, exp_bits, fraction) do
    <<float::float-64>> = <<sign_bit::1, exp_bits::11, fraction::52>>
    float
  end

  defp integer_bit_length(integer) do
    bytes = :binary.encode_unsigned(integer)
    <<first, _rest::binary>> = bytes
    (:erlang.byte_size(bytes) - 1) * 8 + byte_bit_length(first)
  end

  defp byte_bit_length(byte) when byte >= 128, do: 8
  defp byte_bit_length(byte) when byte >= 64, do: 7
  defp byte_bit_length(byte) when byte >= 32, do: 6
  defp byte_bit_length(byte) when byte >= 16, do: 5
  defp byte_bit_length(byte) when byte >= 8, do: 4
  defp byte_bit_length(byte) when byte >= 4, do: 3
  defp byte_bit_length(byte) when byte >= 2, do: 2
  defp byte_bit_length(_byte), do: 1
end
