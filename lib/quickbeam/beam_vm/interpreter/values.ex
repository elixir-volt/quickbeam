defmodule QuickBEAM.BeamVM.Interpreter.Values do
  alias QuickBEAM.BeamVM.Bytecode
  import Bitwise

  def truthy?(nil), do: false
  def truthy?(:undefined), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(""), do: false
  def truthy?(_), do: true

  def falsy?(val), do: not truthy?(val)

  def to_number(val) when is_number(val), do: val
  def to_number(true), do: 1
  def to_number(false), do: 0
  def to_number(nil), do: 0
  def to_number(:undefined), do: :nan
  def to_number(:infinity), do: :infinity
  def to_number(:neg_infinity), do: :neg_infinity
  def to_number(:nan), do: :nan
  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _rest} when trunc(f) == f -> trunc(f)
      {f, _} -> f
      :error -> :nan
    end
  end
  def to_number({:obj, _} = obj) do
    map = QuickBEAM.BeamVM.Heap.get_obj(elem(obj, 1), %{})
    case Map.get(map, "valueOf") do
      fun when fun != nil and fun != :undefined ->
        ctx = QuickBEAM.BeamVM.Heap.get_ctx() || %QuickBEAM.BeamVM.Interpreter.Ctx{}
        QuickBEAM.BeamVM.Heap.put_ctx(%{ctx | this: obj})
        result = QuickBEAM.BeamVM.Interpreter.invoke(fun, [], 10_000_000)
        to_number(result)
      _ -> :nan
    end
  end
  def to_number(_), do: :nan

  def to_int32(val) when is_integer(val), do: val
  def to_int32(val) when is_float(val), do: trunc(val)
  def to_int32(_), do: 0

  def to_js_string(:undefined), do: "undefined"
  def to_js_string(nil), do: "null"
  def to_js_string(true), do: "true"
  def to_js_string(false), do: "false"
  def to_js_string(n) when is_integer(n), do: Integer.to_string(n)
  def to_js_string(n) when is_float(n), do: Float.to_string(n)
  def to_js_string(s) when is_binary(s), do: s
  def to_js_string({:obj, _} = obj) do
    map = QuickBEAM.BeamVM.Heap.get_obj(elem(obj, 1), %{})
    case Map.get(map, "toString") do
      fun when fun != nil and fun != :undefined ->
        ctx = QuickBEAM.BeamVM.Heap.get_ctx() || %QuickBEAM.BeamVM.Interpreter.Ctx{}
        QuickBEAM.BeamVM.Heap.put_ctx(%{ctx | this: obj})
        result = QuickBEAM.BeamVM.Interpreter.invoke(fun, [], 10_000_000)
        to_js_string(result)
      _ -> "[object Object]"
    end
  end
  def to_js_string(_), do: "[object]"

  def typeof(:undefined), do: "undefined"
  def typeof(:nan), do: "number"
  def typeof(:infinity), do: "number"
  def typeof(nil), do: "object"
  def typeof(true), do: "boolean"
  def typeof(false), do: "boolean"
  def typeof(val) when is_number(val), do: "number"
  def typeof(val) when is_binary(val), do: "string"
  def typeof(%Bytecode.Function{}), do: "function"
  def typeof({:closure, _, %Bytecode.Function{}}), do: "function"
  def typeof({:builtin, _, _}), do: "function"
  def typeof(_), do: "object"

  def strict_eq(:nan, :nan), do: false
  def strict_eq(:infinity, :infinity), do: true
  def strict_eq(:neg_infinity, :neg_infinity), do: true
  def strict_eq(a, b), do: a === b

  def add(a, b) when is_binary(a) or is_binary(b), do: to_js_string(a) <> to_js_string(b)
  def add(a, b) when is_number(a) and is_number(b), do: a + b
  def add(a, b), do: numeric_add(to_number(a), to_number(b))

  def numeric_add(a, b) when is_number(a) and is_number(b), do: a + b
  def numeric_add(:nan, _), do: :nan
  def numeric_add(_, :nan), do: :nan
  def numeric_add(:infinity, :neg_infinity), do: :nan
  def numeric_add(:neg_infinity, :infinity), do: :nan
  def numeric_add(:infinity, _), do: :infinity
  def numeric_add(:neg_infinity, _), do: :neg_infinity
  def numeric_add(_, :infinity), do: :infinity
  def numeric_add(_, :neg_infinity), do: :neg_infinity
  def numeric_add(_, _), do: :nan

  def sub(a, b) when is_number(a) and is_number(b), do: a - b
  def sub(a, b), do: numeric_add(to_number(a), neg(to_number(b)))

  def mul(a, b) when is_number(a) and is_number(b), do: a * b
  def mul(a, b) do
    na = to_number(a)
    nb = to_number(b)
    cond do
      na == :nan or nb == :nan -> :nan
      na in [:infinity, :neg_infinity] or nb in [:infinity, :neg_infinity] ->
        if na == 0 or nb == 0 do
          :nan
        else
          sa = if na in [:neg_infinity] or (is_number(na) and na < 0), do: -1, else: 1
          sb = if nb in [:neg_infinity] or (is_number(nb) and nb < 0), do: -1, else: 1
          if sa * sb > 0, do: :infinity, else: :neg_infinity
        end
      is_number(na) and is_number(nb) -> na * nb
      true -> :nan
    end
  end

  def div(a, b) when is_number(a) and is_number(b) do
    cond do
      b == 0 and neg_zero?(b) ->
        if a > 0, do: :neg_infinity, else: if(a < 0, do: :infinity, else: :nan)
      b == 0 -> inf_or_nan(a)
      true -> a / b
    end
  end
  def div(a, b), do: to_number(a) / to_number(b)

  def mod(a, b) when is_number(a) and is_number(b), do: if(b == 0, do: :nan, else: rem(trunc(a), trunc(b)))
  def mod(_, _), do: :nan

  def pow(a, b) when is_number(a) and is_number(b), do: :math.pow(a, b)
  def pow(_, _), do: :nan

  def neg(0), do: -0.0
  def neg(:infinity), do: :neg_infinity
  def neg(:neg_infinity), do: :infinity
  def neg(:nan), do: :nan
  def neg(a) when is_number(a), do: -a
  def neg(a), do: neg(to_number(a))

  def neg_zero?(b), do: is_float(b) and b == 0.0 and hd(:erlang.float_to_list(b)) == ?-

  def inf_or_nan(a) when a > 0, do: :infinity
  def inf_or_nan(a) when a < 0, do: :neg_infinity
  def inf_or_nan(_), do: :nan

  def band(a, b), do: Bitwise.band(to_int32(a), to_int32(b))
  def bor(a, b), do: Bitwise.bor(to_int32(a), to_int32(b))
  def bxor(a, b), do: Bitwise.bxor(to_int32(a), to_int32(b))
  def shl(a, b), do: Bitwise.bsl(to_int32(a), Bitwise.band(to_int32(b), 31))
  def sar(a, b), do: Bitwise.bsr(to_int32(a), Bitwise.band(to_int32(b), 31))

  def shr(a, b) do
    ua = to_int32(a) &&& 0xFFFFFFFF
    Bitwise.bsr(ua, Bitwise.band(to_int32(b), 31))
  end

  def lt(a, b) when is_number(a) and is_number(b), do: a < b
  def lt(a, b) when is_binary(a) and is_binary(b), do: a < b
  def lt(a, b), do: to_number(a) < to_number(b)

  def lte(a, b) when is_number(a) and is_number(b), do: a <= b
  def lte(a, b) when is_binary(a) and is_binary(b), do: a <= b
  def lte(a, b), do: to_number(a) <= to_number(b)

  def gt(a, b) when is_number(a) and is_number(b), do: a > b
  def gt(a, b) when is_binary(a) and is_binary(b), do: a > b
  def gt(a, b), do: to_number(a) > to_number(b)

  def gte(a, b) when is_number(a) and is_number(b), do: a >= b
  def gte(a, b) when is_binary(a) and is_binary(b), do: a >= b
  def gte(a, b), do: to_number(a) >= to_number(b)

  def eq(a, b), do: abstract_eq(a, b)
  def neq(a, b), do: not abstract_eq(a, b)

  def abstract_eq(nil, nil), do: true
  def abstract_eq(nil, :undefined), do: true
  def abstract_eq(:undefined, nil), do: true
  def abstract_eq(:undefined, :undefined), do: true
  def abstract_eq(a, b) when is_number(a) and is_number(b), do: a == b
  def abstract_eq(a, b) when is_binary(a) and is_binary(b), do: a == b
  def abstract_eq(a, b) when is_boolean(a) and is_boolean(b), do: a == b
  def abstract_eq(true, b), do: abstract_eq(1, b)
  def abstract_eq(a, true), do: abstract_eq(a, 1)
  def abstract_eq(false, b), do: abstract_eq(0, b)
  def abstract_eq(a, false), do: abstract_eq(a, 0)
  def abstract_eq(a, b) when is_number(a) and is_binary(b), do: a == to_number(b)
  def abstract_eq(a, b) when is_binary(a) and is_number(b), do: to_number(a) == b
  def abstract_eq(_, _), do: false
end
