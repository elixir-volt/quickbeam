defmodule QuickBEAM.BeamVM.Runtime.Math do
  @moduledoc false

  alias QuickBEAM.BeamVM.Runtime

  # ── Math ──

  def object do
    {:builtin, "Math",
     %{
       "floor" => {:builtin, "floor", fn [a | _], _this -> floor(Runtime.to_float(a)) end},
       "ceil" => {:builtin, "ceil", fn [a | _], _this -> ceil(Runtime.to_float(a)) end},
       "round" => {:builtin, "round", fn [a | _], _this -> round(Runtime.to_float(a)) end},
       "abs" => {:builtin, "abs", fn [a | _], _this -> abs(a) end},
       "max" =>
         {:builtin, "max",
          fn
            [], _this -> :neg_infinity
            args, _this -> Enum.max(args)
          end},
       "min" =>
         {:builtin, "min",
          fn
            [], _this -> :infinity
            args, _this -> Enum.min(args)
          end},
       "sqrt" => {:builtin, "sqrt", fn [a | _], _this -> :math.sqrt(Runtime.to_float(a)) end},
       "pow" =>
         {:builtin, "pow",
          fn [a, b | _], _this -> :math.pow(Runtime.to_float(a), Runtime.to_float(b)) end},
       "random" => {:builtin, "random", fn _, _this -> :rand.uniform() end},
       "trunc" => {:builtin, "trunc", fn [a | _], _this -> trunc(Runtime.to_float(a)) end},
       "sign" =>
         {:builtin, "sign",
          fn [a | _], _this ->
            cond do
              is_number(a) and a > 0 -> 1
              is_number(a) and a < 0 -> -1
              is_number(a) -> a
              true -> :nan
            end
          end},
       "log" => {:builtin, "log", fn [a | _], _this -> :math.log(Runtime.to_float(a)) end},
       "log2" => {:builtin, "log2", fn [a | _], _this -> :math.log2(Runtime.to_float(a)) end},
       "log10" => {:builtin, "log10", fn [a | _], _this -> :math.log10(Runtime.to_float(a)) end},
       "sin" => {:builtin, "sin", fn [a | _], _this -> :math.sin(Runtime.to_float(a)) end},
       "cos" => {:builtin, "cos", fn [a | _], _this -> :math.cos(Runtime.to_float(a)) end},
       "tan" => {:builtin, "tan", fn [a | _], _this -> :math.tan(Runtime.to_float(a)) end},
       "PI" => :math.pi(),
       "E" => :math.exp(1),
       "LN2" => :math.log(2),
       "LN10" => :math.log(10),
       "LOG2E" => :math.log2(:math.exp(1)),
       "LOG10E" => :math.log10(:math.exp(1)),
       "SQRT2" => :math.sqrt(2),
       "SQRT1_2" => :math.sqrt(2) / 2,
       "MAX_SAFE_INTEGER" => 9_007_199_254_740_991,
       "MIN_SAFE_INTEGER" => -9_007_199_254_740_991,
       "clz32" =>
         {:builtin, "clz32",
          fn [a | _], _this ->
            n = QuickBEAM.BeamVM.Interpreter.Values.to_uint32(a)
            if n == 0, do: 32, else: 31 - trunc(:math.log2(n))
          end},
       "fround" =>
         {:builtin, "fround",
          fn [a | _], _this ->
            f = Runtime.to_float(a)
            <<f32::float-32>> = <<f::float-32>>
            f32 * 1.0
          end},
       "imul" =>
         {:builtin, "imul",
          fn [a, b | _], _this ->
            QuickBEAM.BeamVM.Interpreter.Values.to_int32(
              QuickBEAM.BeamVM.Interpreter.Values.to_int32(a) *
                QuickBEAM.BeamVM.Interpreter.Values.to_int32(b)
            )
          end},
       "atan2" =>
         {:builtin, "atan2",
          fn [a, b | _], _this -> :math.atan2(Runtime.to_float(a), Runtime.to_float(b)) end},
       "asin" => {:builtin, "asin", fn [a | _], _this -> :math.asin(Runtime.to_float(a)) end},
       "acos" => {:builtin, "acos", fn [a | _], _this -> :math.acos(Runtime.to_float(a)) end},
       "atan" => {:builtin, "atan", fn [a | _], _this -> :math.atan(Runtime.to_float(a)) end},
       "exp" => {:builtin, "exp", fn [a | _], _this -> :math.exp(Runtime.to_float(a)) end},
       "cbrt" =>
         {:builtin, "cbrt",
          fn [a | _], _this ->
            f = Runtime.to_float(a)
            sign = if f < 0, do: -1, else: 1
            sign * :math.pow(abs(f), 1.0 / 3.0)
          end},
       "log1p" =>
         {:builtin, "log1p", fn [a | _], _this -> :math.log(1 + Runtime.to_float(a)) end},
       "expm1" =>
         {:builtin, "expm1", fn [a | _], _this -> :math.exp(Runtime.to_float(a)) - 1 end},
       "cosh" => {:builtin, "cosh", fn [a | _], _this -> :math.cosh(Runtime.to_float(a)) end},
       "sinh" => {:builtin, "sinh", fn [a | _], _this -> :math.sinh(Runtime.to_float(a)) end},
       "tanh" => {:builtin, "tanh", fn [a | _], _this -> :math.tanh(Runtime.to_float(a)) end},
       "acosh" => {:builtin, "acosh", fn [a | _], _this -> :math.acosh(Runtime.to_float(a)) end},
       "asinh" => {:builtin, "asinh", fn [a | _], _this -> :math.asinh(Runtime.to_float(a)) end},
       "atanh" => {:builtin, "atanh", fn [a | _], _this -> :math.atanh(Runtime.to_float(a)) end},
       "sumPrecise" =>
         {:builtin, "sumPrecise",
          fn [arr | _], _this ->
            list =
              case arr do
                {:obj, ref} ->
                  data = QuickBEAM.BeamVM.Heap.get_obj(ref, [])
                  if is_list(data), do: data, else: []

                l when is_list(l) ->
                  l

                _ ->
                  []
              end

            Enum.reduce(list, 0.0, fn v, acc -> acc + Runtime.to_float(v) end)
          end},
       "hypot" =>
         {:builtin, "hypot",
          fn args, _this ->
            sum = Enum.reduce(args, 0.0, fn a, acc -> acc + :math.pow(Runtime.to_float(a), 2) end)
            :math.sqrt(sum)
          end}
     }}
  end
end
