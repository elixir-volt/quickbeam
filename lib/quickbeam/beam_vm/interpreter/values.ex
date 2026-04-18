defmodule QuickBEAM.BeamVM.Interpreter.Values do
  @compile {:inline,
            truthy?: 1,
            falsy?: 1,
            to_int32: 1,
            strict_eq: 2,
            add: 2,
            sub: 2,
            mul: 2,
            neg: 1,
            typeof: 1,
            to_number: 1,
            to_js_string: 1,
            lt: 2,
            lte: 2,
            gt: 2,
            gte: 2,
            eq: 2,
            neq: 2,
            band: 2,
            bor: 2,
            bxor: 2,
            shl: 2,
            sar: 2,
            shr: 2,
            numeric_add: 2}
  alias QuickBEAM.BeamVM.Bytecode
  import Bitwise

  def truthy?(nil), do: false
  def truthy?(:undefined), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(""), do: false
  def truthy?({:bigint, 0}), do: false
  def truthy?({:bigint, _}), do: true
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
    s = String.trim(s)

    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> :nan
        end
    end
  end

  def to_number({:bigint, _}),
    do:
      throw(
        {:js_throw,
         %{"message" => "Cannot convert a BigInt value to a number", "name" => "TypeError"}}
      )

  def to_number({:obj, _} = obj) do
    map = QuickBEAM.BeamVM.Heap.get_obj(elem(obj, 1), %{})

    case Map.get(map, "valueOf") do
      fun when fun != nil and fun != :undefined ->
        to_number(QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(fun, [], 10_000_000, obj))

      _ ->
        :nan
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
  def to_js_string(n) when is_float(n) and n == 0.0, do: "0"
  def to_js_string(n) when is_float(n), do: format_float(n)
  def to_js_string({:bigint, n}), do: Integer.to_string(n)
  def to_js_string({:symbol, desc}), do: "Symbol(#{desc})"
  def to_js_string({:symbol, desc, _ref}), do: "Symbol(#{desc})"
  def to_js_string(s) when is_binary(s), do: s

  def to_js_string({:obj, _} = obj) do
    map = QuickBEAM.BeamVM.Heap.get_obj(elem(obj, 1), %{})

    case Map.get(map, "toString") do
      fun when fun != nil and fun != :undefined ->
        to_js_string(QuickBEAM.BeamVM.Interpreter.invoke_with_receiver(fun, [], 10_000_000, obj))

      _ ->
        "[object Object]"
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
  def typeof({:symbol, _}), do: "symbol"
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:bigint, _}), do: "bigint"
  def typeof({:builtin, _, _}), do: "function"
  def typeof(_), do: "object"

  def strict_eq(:nan, :nan), do: false
  def strict_eq(:infinity, :infinity), do: true
  def strict_eq(:neg_infinity, :neg_infinity), do: true
  def strict_eq({:bigint, a}, {:bigint, b}), do: a == b
  def strict_eq({:symbol, _, ref1}, {:symbol, _, ref2}), do: ref1 === ref2
  def strict_eq(a, b) when is_number(a) and is_number(b), do: a == b
  def strict_eq(a, b), do: a === b

  def add({:bigint, a}, {:bigint, b}), do: {:bigint, a + b}
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

  def sub({:bigint, a}, {:bigint, b}), do: {:bigint, a - b}
  def sub(a, b) when is_number(a) and is_number(b), do: a - b
  def sub(a, b), do: numeric_add(to_number(a), neg(to_number(b)))

  def mul({:bigint, a}, {:bigint, b}), do: {:bigint, a * b}
  def mul(a, b) when is_number(a) and is_number(b), do: a * b

  def mul(a, b) do
    na = to_number(a)
    nb = to_number(b)

    cond do
      na == :nan or nb == :nan ->
        :nan

      na in [:infinity, :neg_infinity] or nb in [:infinity, :neg_infinity] ->
        if na == 0 or nb == 0 do
          :nan
        else
          sa = if na in [:neg_infinity] or (is_number(na) and na < 0), do: -1, else: 1
          sb = if nb in [:neg_infinity] or (is_number(nb) and nb < 0), do: -1, else: 1
          if sa * sb > 0, do: :infinity, else: :neg_infinity
        end

      # Reached when one or both args were non-numeric but to_number made them numeric (e.g. booleans)
      is_number(na) and is_number(nb) ->
        na * nb

      true ->
        :nan
    end
  end

  def div({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, Kernel.div(a, b)}

  def div({:bigint, _}, {:bigint, 0}),
    do: throw({:js_throw, %{"message" => "Division by zero", "name" => "RangeError"}})

  def div(a, b) when is_number(a) and is_number(b) do
    cond do
      b == 0 and neg_zero?(b) ->
        if a > 0, do: :neg_infinity, else: if(a < 0, do: :infinity, else: :nan)

      b == 0 ->
        inf_or_nan(a)

      true ->
        a / b
    end
  end

  def div(a, b) do
    na = to_number(a)
    nb = to_number(b)

    cond do
      na == :nan or nb == :nan ->
        :nan

      na in [:infinity, :neg_infinity] or nb in [:infinity, :neg_infinity] ->
        div_inf(na, nb)

      is_number(na) and is_number(nb) ->
        cond do
          nb == 0 and neg_zero?(nb) ->
            if na > 0, do: :neg_infinity, else: if(na < 0, do: :infinity, else: :nan)

          nb == 0 ->
            inf_or_nan(na)

          true ->
            na / nb
        end

      true ->
        :nan
    end
  end

  defp div_inf(:infinity, :infinity), do: :nan
  defp div_inf(:infinity, :neg_infinity), do: :nan
  defp div_inf(:neg_infinity, :infinity), do: :nan
  defp div_inf(:neg_infinity, :neg_infinity), do: :nan
  defp div_inf(:infinity, n) when is_number(n) and n > 0, do: :infinity
  defp div_inf(:infinity, n) when is_number(n) and n < 0, do: :neg_infinity
  defp div_inf(:neg_infinity, n) when is_number(n) and n > 0, do: :neg_infinity
  defp div_inf(:neg_infinity, n) when is_number(n) and n < 0, do: :infinity
  defp div_inf(n, :infinity) when is_number(n), do: 0.0
  defp div_inf(n, :neg_infinity) when is_number(n), do: -0.0
  defp div_inf(_, _), do: :nan

  def mod({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, rem(a, b)}

  def mod({:bigint, _}, {:bigint, 0}),
    do: throw({:js_throw, %{"message" => "Division by zero", "name" => "RangeError"}})

  def mod(a, b) when is_number(a) and is_number(b),
    do: if(b == 0, do: :nan, else: rem(trunc(a), trunc(b)))

  def mod(_, _), do: :nan

  def pow({:bigint, a}, {:bigint, b}) when b >= 0, do: {:bigint, Integer.pow(a, b)}
  def pow(a, b) when is_number(a) and is_number(b), do: :math.pow(a, b)
  def pow(_, _), do: :nan

  def neg({:bigint, a}), do: {:bigint, -a}
  def neg(0), do: -0.0
  def neg(:infinity), do: :neg_infinity
  def neg(:neg_infinity), do: :infinity
  def neg(:nan), do: :nan
  def neg(a) when is_number(a), do: -a
  def neg(a), do: neg(to_number(a))

  def neg_zero?(b), do: is_float(b) and b == 0.0 and hd(:erlang.float_to_list(b)) == ?-

  defp format_float(n) do
    if n == trunc(n) and abs(n) < 1.0e20 do
      Integer.to_string(trunc(n))
    else
      :erlang.float_to_binary(n, [{:decimals, 20}, :compact])
    end
  end

  def inf_or_nan(a) when a > 0, do: :infinity
  def inf_or_nan(a) when a < 0, do: :neg_infinity
  def inf_or_nan(_), do: :nan

  def band({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.band(a, b)}
  def band(a, b), do: Bitwise.band(to_int32(a), to_int32(b))
  def bor({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bor(a, b)}
  def bor(a, b), do: Bitwise.bor(to_int32(a), to_int32(b))
  def bxor({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bxor(a, b)}
  def bxor(a, b), do: Bitwise.bxor(to_int32(a), to_int32(b))

  def shl({:bigint, a}, {:bigint, b}) when b >= 0 and b <= 1_000_000,
    do: {:bigint, Bitwise.bsl(a, b)}

  def shl({:bigint, _}, {:bigint, _}),
    do: throw({:js_throw, %{"message" => "Maximum BigInt size exceeded", "name" => "RangeError"}})

  def shl(a, b), do: Bitwise.bsl(to_int32(a), Bitwise.band(to_int32(b), 31))
  def sar({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bsr(a, b)}
  def sar(a, b), do: Bitwise.bsr(to_int32(a), Bitwise.band(to_int32(b), 31))

  def shr(a, b) do
    ua = to_int32(a) &&& 0xFFFFFFFF
    Bitwise.bsr(ua, Bitwise.band(to_int32(b), 31))
  end

  def lt({:bigint, a}, {:bigint, b}), do: a < b
  def lt(a, b) when is_number(a) and is_number(b), do: a < b
  def lt(a, b) when is_binary(a) and is_binary(b), do: a < b
  def lt(a, b), do: to_number(a) < to_number(b)

  def lte({:bigint, a}, {:bigint, b}), do: a <= b
  def lte(a, b) when is_number(a) and is_number(b), do: a <= b
  def lte(a, b) when is_binary(a) and is_binary(b), do: a <= b
  def lte(a, b), do: to_number(a) <= to_number(b)

  def gt({:bigint, a}, {:bigint, b}), do: a > b
  def gt(a, b) when is_number(a) and is_number(b), do: a > b
  def gt(a, b) when is_binary(a) and is_binary(b), do: a > b
  def gt(a, b), do: to_number(a) > to_number(b)

  def gte({:bigint, a}, {:bigint, b}), do: a >= b
  def gte(a, b) when is_number(a) and is_number(b), do: a >= b
  def gte(a, b) when is_binary(a) and is_binary(b), do: a >= b
  def gte(a, b), do: to_number(a) >= to_number(b)

  def eq({:bigint, a}, {:bigint, b}), do: a == b
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
  def abstract_eq({:bigint, a}, b) when is_integer(b), do: a == b
  def abstract_eq({:bigint, a}, b) when is_float(b), do: a == b
  def abstract_eq(a, {:bigint, b}) when is_integer(a), do: a == b
  def abstract_eq(a, {:bigint, b}) when is_float(a), do: a == b
  def abstract_eq(_, _), do: false
end
