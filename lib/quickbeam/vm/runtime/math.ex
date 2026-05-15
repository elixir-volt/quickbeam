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
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n -> floor(n)
      end
    end

    method "ceil" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        n -> ceil(n)
      end
    end

    method "round" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
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
      case args do
        [] -> :neg_infinity
        _ -> Enum.max(args)
      end
    end

    method "min" do
      case args do
        [] -> :infinity
        _ -> Enum.min(args)
      end
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
      trunc(Runtime.to_float(hd(args)))
    end

    method "sign" do
      a = hd(args)

      cond do
        is_number(a) and a > 0 -> 1
        is_number(a) and a < 0 -> -1
        is_number(a) -> a
        true -> :nan
      end
    end

    method "log" do
      math_log(Runtime.to_float(hd(args)), &:math.log/1)
    end

    method "log2" do
      math_log(Runtime.to_float(hd(args)), &:math.log2/1)
    end

    method "log10" do
      math_log(Runtime.to_float(hd(args)), &:math.log10/1)
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
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> :neg_infinity
        :nan -> :nan
        f ->
          sign = if f < 0, do: -1, else: 1
          sign * :math.pow(abs(f), 1.0 / 3.0)
      end
    end

    method "log1p" do
      math_log(1 + Runtime.to_float(hd(args)), &:math.log/1)
    end

    method "expm1" do
      case Runtime.to_float(hd(args)) do
        :infinity -> :infinity
        :neg_infinity -> -1
        :nan -> :nan
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
      sum = Enum.reduce(args, 0.0, fn a, acc -> acc + :math.pow(Runtime.to_float(a), 2) end)
      :math.sqrt(sum)
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
  defp math_log(0, _fun), do: :neg_infinity
  defp math_log(n, fun), do: fun.(n)

  defp math_atan2(:nan, _), do: :nan
  defp math_atan2(_, :nan), do: :nan
  defp math_atan2(:infinity, :infinity), do: :math.pi() / 4
  defp math_atan2(:infinity, :neg_infinity), do: 3 * :math.pi() / 4
  defp math_atan2(:neg_infinity, :infinity), do: -:math.pi() / 4
  defp math_atan2(:neg_infinity, :neg_infinity), do: -3 * :math.pi() / 4
  defp math_atan2(:infinity, _), do: :math.pi() / 2
  defp math_atan2(:neg_infinity, _), do: -:math.pi() / 2
  defp math_atan2(_, :infinity), do: 0
  defp math_atan2(y, :neg_infinity) when is_number(y) and y >= 0, do: :math.pi()
  defp math_atan2(_, :neg_infinity), do: -:math.pi()
  defp math_atan2(y, x), do: :math.atan2(y, x)

  defp math_pow(_base, 0), do: 1
  defp math_pow(:nan, _exp), do: :nan
  defp math_pow(_base, :nan), do: :nan
  defp math_pow(:infinity, exp) when is_number(exp) and exp > 0, do: :infinity
  defp math_pow(:infinity, exp) when is_number(exp) and exp < 0, do: 0
  defp math_pow(:neg_infinity, exp) when is_number(exp) and exp > 0, do: :infinity
  defp math_pow(:neg_infinity, exp) when is_number(exp) and exp < 0, do: 0
  defp math_pow(base, :infinity) when abs(base) > 1, do: :infinity
  defp math_pow(base, :infinity) when abs(base) < 1, do: 0
  defp math_pow(base, :neg_infinity) when abs(base) > 1, do: 0
  defp math_pow(base, :neg_infinity) when abs(base) < 1, do: :infinity
  defp math_pow(base, exp) do
    try do
      :math.pow(base, exp)
    rescue
      ArithmeticError -> :nan
    end
  end

  defp shewchuk_sum(list) do
    partials =
      Enum.reduce(list, [], fn v, partials ->
        x = Runtime.to_float(v)
        grow(partials, x, [])
      end)

    case partials do
      [] ->
        0.0

      [x] ->
        x

      _ ->
        partials = Enum.reverse(partials)
        finalize_partials(partials)
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
