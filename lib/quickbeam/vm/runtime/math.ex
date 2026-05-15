defmodule QuickBEAM.VM.Runtime.Math do
  @moduledoc "JS `Math` object: all standard methods (`floor`, `ceil`, `sin`, `random`, etc.) and numeric constants."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor
  alias QuickBEAM.VM.Runtime

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
    Enum.each(@method_lengths, fn {name, length} ->
      method = Map.get(map, name)
      Heap.put_ctor_static(math, name, method)
      Heap.put_prop_desc(math, name, PropertyDescriptor.method())
      Heap.put_ctor_prop_desc(math, name, PropertyDescriptor.method())

      case method do
        {:builtin, _, _} = method ->
          Heap.put_ctor_static(method, "length", length)
          Heap.put_ctor_prop_desc(method, "length", PropertyDescriptor.hidden_readonly())

        _ ->
          :ok
      end
    end)

    Enum.each(@constants, fn name ->
      descriptor = PropertyDescriptor.attrs(writable: false, enumerable: false, configurable: false)
      Heap.put_prop_desc(math, name, descriptor)
      Heap.put_ctor_prop_desc(math, name, descriptor)
    end)

    tag = {:symbol, "Symbol.toStringTag"}
    Heap.put_ctor_static(math, tag, "Math")
    Heap.put_prop_desc(math, tag, PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(math, tag, PropertyDescriptor.hidden_readonly())

    case Heap.get_object_prototype() do
      {:obj, _} = object_proto -> Heap.put_ctor_static(math, proto(), object_proto)
      _ -> :ok
    end

    math
  end

  js_object "Math" do
    method "floor" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n when n == 0 -> n
        n -> floor(n)
      end
    end

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

    method "round" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n when n == 0 -> n
        n when n >= -0.5 and n < 0 -> -0.0
        n -> round(n)
      end
    end

    method "abs" do
      case hd(args) do
        :infinity -> :infinity
        :neg_infinity -> :infinity
        :nan -> :nan
        n when is_number(n) -> abs(n)
        _ -> :nan
      end
    end

    method "max" do
      extremum(args, :max)
    end

    method "min" do
      extremum(args, :min)
    end

    method "sqrt" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :nan
        :nan -> :nan
        n when n < 0 -> :nan
        n -> :math.sqrt(n)
      end
    end

    method "pow" do
      [a, b | _] = args
      math_pow(Runtime.to_float(a), Runtime.to_float(b))
    end

    method "random" do
      :rand.uniform()
    end

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

    method "log" do
      math_log(Runtime.to_number(hd(args)), &:math.log/1)
    end

    method "log2" do
      math_log(Runtime.to_number(hd(args)), &:math.log2/1)
    end

    method "log10" do
      math_log(Runtime.to_number(hd(args)), &:math.log10/1)
    end

    method "sin" do
      trig(Runtime.to_float(hd(args)), &:math.sin/1)
    end

    method "cos" do
      trig(Runtime.to_float(hd(args)), &:math.cos/1)
    end

    method "tan" do
      trig(Runtime.to_float(hd(args)), &:math.tan/1)
    end

    method "clz32" do
      n = Values.to_uint32(hd(args))
      if n == 0, do: 32, else: 31 - trunc(:math.log2(n))
    end

    method "f16round" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        f -> f16round(f)
      end
    end

    method "fround" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        f ->
          <<f32::float-32>> = <<f::float-32>>
          f32 * 1.0
      end
    end

    method "imul" do
      [a, b | _] = args

      Values.to_int32(
        Values.to_int32(a) *
          Values.to_int32(b)
      )
    end

    method "atan2" do
      [a, b | _] = args
      math_atan2(Runtime.to_float(a), Runtime.to_float(b))
    end

    method "asin" do
      inverse_unit(Runtime.to_float(hd(args)), &:math.asin/1)
    end

    method "acos" do
      inverse_unit(Runtime.to_float(hd(args)), &:math.acos/1)
    end

    method "atan" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :math.pi() / 2
        :neg_infinity -> -:math.pi() / 2
        :nan -> :nan
        n -> :math.atan(n)
      end
    end

    method "exp" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> 0
        :nan -> :nan
        n -> :math.exp(n)
      end
    end

    method "cbrt" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        f when f == 0 -> f
        f ->
          sign = if f < 0, do: -1, else: 1
          sign * :math.pow(abs(f), 1.0 / 3.0)
      end
    end

    method "log1p" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :nan
        :nan -> :nan
        n when n == 0 -> n
        n -> math_log(1 + n, &:math.log/1)
      end
    end

    method "expm1" do
      case Runtime.to_number(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> -1
        :nan -> :nan
        n when n == 0 -> n
        n -> :math.exp(n) - 1
      end
    end

    method "cosh" do
      hyperbolic(Runtime.to_float(hd(args)), &:math.cosh/1)
    end

    method "sinh" do
      signed_hyperbolic(Runtime.to_float(hd(args)), &:math.sinh/1)
    end

    method "tanh" do
      case Runtime.to_float(hd(args)) do
        :infinity -> 1
        :neg_infinity -> -1
        :nan -> :nan
        n -> :math.tanh(n)
      end
    end

    method "acosh" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :nan
        :nan -> :nan
        n when n < 1 -> :nan
        n -> :math.acosh(n)
      end
    end

    method "asinh" do
      signed_hyperbolic(Runtime.to_float(hd(args)), &:math.asinh/1)
    end

    method "atanh" do
      case Runtime.to_float(hd(args)) do
        :nan -> :nan
        n when n == 1 -> :infinity
        n when n == -1 -> :neg_infinity
        n when n < -1 or n > 1 -> :nan
        n -> :math.atanh(n)
      end
    end

    method "sumPrecise" do
      list =
        case hd(args) do
          {:obj, ref} ->
            data = Heap.get_obj(ref, [])

            case data do
              {:qb_arr, arr} -> :array.to_list(arr)
              l when is_list(l) -> l
              _ -> []
            end

          {:qb_arr, arr} ->
            :array.to_list(arr)

          l when is_list(l) ->
            l

          _ ->
            []
        end

      shewchuk_sum(list)
    end

    method "hypot" do
      values = Enum.map(args, &Runtime.to_float/1)

      cond do
        Enum.any?(values, &(&1 in [:infinity, :neg_infinity])) -> :infinity
        Enum.any?(values, &(&1 == :nan)) -> :nan
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
        {exponent, fraction} = if fraction == 1024, do: {exponent + 1, 0}, else: {exponent, fraction}
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

  defp odd_integer?(value), do: is_integer(value) or (is_float(value) and value == trunc(value) and rem(trunc(value), 2) != 0)

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
    unless Enum.all?(list, &(is_number(&1) or &1 in [:nan, :infinity, :neg_infinity])) do
      QuickBEAM.VM.JSThrow.type_error!("Math.sumPrecise requires numbers")
    end
  end

  defp all_negative_zero?([]), do: true
  defp all_negative_zero?(list), do: Enum.all?(list, &Values.neg_zero?/1)

  defp finite_sum(list) do
    partials =
      Enum.reduce(list, [], fn v, partials ->
        x = Runtime.to_float(v)
        grow(partials, x, [])
      end)

    case partials do
      [] -> 0.0
      [x] -> x
      _ -> partials |> Enum.reverse() |> finalize_partials()
    end
  end

  defp grow([], x, new_partials), do: if(x != 0.0, do: new_partials ++ [x], else: new_partials)

  defp grow([p | rest], x, new_partials) do
    {hi, lo} = two_sum(x, p)
    new_partials = if lo != 0.0, do: new_partials ++ [lo], else: new_partials
    grow(rest, hi, new_partials)
  end

  # CPython fsum-style finalization: detect halfway cases where
  # remaining partials should break the tie
  defp finalize_partials([]), do: 0.0
  defp finalize_partials([x]), do: x

  defp finalize_partials(partials) do
    [hi | rest] = partials
    {hi, lo, remaining} = fold_top(hi, rest)

    cond do
      lo == 0.0 ->
        hi

      remaining == [] ->
        hi + lo

      true ->
        [next | _] = remaining
        # lo is the rounding error. If remaining partials have the same sign
        # as lo, the true value is farther from hi than lo suggests — round away
        if (lo > 0 and next > 0) or (lo < 0 and next < 0) do
          # Adjust lo to break tie in favor of rounding away from hi
          nudged = lo + lo
          result = hi + nudged
          if result == hi + lo, do: hi + lo, else: result
        else
          hi + lo
        end
    end
  end

  defp fold_top(hi, []), do: {hi, 0.0, []}

  defp fold_top(hi, [lo | rest]) do
    {s, t} = two_sum(hi, lo)
    if t == 0.0, do: fold_top(s, rest), else: {s, t, rest}
  end

  defp two_sum(a, b) do
    s = a + b
    v = s - a
    t = a - (s - v) + (b - v)
    {s, t}
  end
end
