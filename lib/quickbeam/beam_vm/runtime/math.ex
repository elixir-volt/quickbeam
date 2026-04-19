defmodule QuickBEAM.BeamVM.Runtime.Math do
  @moduledoc false

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Interpreter.Values
  alias QuickBEAM.BeamVM.Heap

  js_object "Math" do
    method "floor" do
      floor(Runtime.to_float(hd(args)))
    end

    method "ceil" do
      ceil(Runtime.to_float(hd(args)))
    end

    method "round" do
      round(Runtime.to_float(hd(args)))
    end

    method "abs" do
      abs(hd(args))
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
            if is_list(data), do: data, else: []

          l when is_list(l) ->
            l

          _ ->
            []
        end

      Enum.reduce(list, 0.0, fn v, acc -> acc + Runtime.to_float(v) end)
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
end
