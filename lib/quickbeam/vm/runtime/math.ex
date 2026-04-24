defmodule QuickBEAM.VM.Runtime.Math do
  @moduledoc false

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Runtime

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
      :math.sqrt(Runtime.to_float(hd(args)))
    end

    method "pow" do
      [a, b | _] = args
      :math.pow(Runtime.to_float(a), Runtime.to_float(b))
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
      :math.log(Runtime.to_float(hd(args)))
    end

    method "log2" do
      :math.log2(Runtime.to_float(hd(args)))
    end

    method "log10" do
      :math.log10(Runtime.to_float(hd(args)))
    end

    method "sin" do
      :math.sin(Runtime.to_float(hd(args)))
    end

    method "cos" do
      :math.cos(Runtime.to_float(hd(args)))
    end

    method "tan" do
      :math.tan(Runtime.to_float(hd(args)))
    end

    method "clz32" do
      n = Values.to_uint32(hd(args))
      if n == 0, do: 32, else: 31 - trunc(:math.log2(n))
    end

    method "fround" do
      f = Runtime.to_float(hd(args))
      <<f32::float-32>> = <<f::float-32>>
      f32 * 1.0
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
      :math.atan2(Runtime.to_float(a), Runtime.to_float(b))
    end

    method "asin" do
      :math.asin(Runtime.to_float(hd(args)))
    end

    method "acos" do
      :math.acos(Runtime.to_float(hd(args)))
    end

    method "atan" do
      :math.atan(Runtime.to_float(hd(args)))
    end

    method "exp" do
      :math.exp(Runtime.to_float(hd(args)))
    end

    method "cbrt" do
      f = Runtime.to_float(hd(args))
      sign = if f < 0, do: -1, else: 1
      sign * :math.pow(abs(f), 1.0 / 3.0)
    end

    method "log1p" do
      :math.log(1 + Runtime.to_float(hd(args)))
    end

    method "expm1" do
      :math.exp(Runtime.to_float(hd(args))) - 1
    end

    method "cosh" do
      :math.cosh(Runtime.to_float(hd(args)))
    end

    method "sinh" do
      :math.sinh(Runtime.to_float(hd(args)))
    end

    method "tanh" do
      :math.tanh(Runtime.to_float(hd(args)))
    end

    method "acosh" do
      :math.acosh(Runtime.to_float(hd(args)))
    end

    method "asinh" do
      :math.asinh(Runtime.to_float(hd(args)))
    end

    method "atanh" do
      :math.atanh(Runtime.to_float(hd(args)))
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
