defmodule QuickBEAM.BeamVM.Interpreter.Values do
  @moduledoc false
  import QuickBEAM.BeamVM.Heap.Keys

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter

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
            stringify: 1,
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
            shr: 2}

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

  def to_number(s) when is_binary(s), do: parse_numeric(String.trim(s))

  def to_number({:bigint, _}),
    do:
      throw(
        {:js_throw,
         %{"message" => "Cannot convert a BigInt value to a number", "name" => "TypeError"}}
      )

  def to_number({:obj, ref} = obj) do
    map = Heap.get_obj(ref, %{})

    case Map.get(map, "valueOf") do
      fun when fun != nil and fun != :undefined ->
        to_number(Interpreter.invoke_with_receiver(fun, [], QuickBEAM.BeamVM.Runtime.gas_budget(), obj))

      _ ->
        :nan
    end
  end

  def to_number(_), do: :nan

  defp parse_numeric(""), do: 0
  defp parse_numeric("0x" <> rest), do: parse_int_or_nan(rest, 16)
  defp parse_numeric("0X" <> rest), do: parse_int_or_nan(rest, 16)
  defp parse_numeric("0o" <> rest), do: parse_int_or_nan(rest, 8)
  defp parse_numeric("0O" <> rest), do: parse_int_or_nan(rest, 8)
  defp parse_numeric("0b" <> rest), do: parse_int_or_nan(rest, 2)
  defp parse_numeric("0B" <> rest), do: parse_int_or_nan(rest, 2)
  defp parse_numeric("Infinity" <> _), do: :infinity
  defp parse_numeric("+Infinity" <> _), do: :infinity
  defp parse_numeric("-Infinity" <> _), do: :neg_infinity

  defp parse_numeric(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> :nan
        end
    end
  end

  defp parse_int_or_nan(s, base) do
    case Integer.parse(s, base) do
      {i, ""} -> i
      _ -> :nan
    end
  end


  def to_int32(val) when is_integer(val), do: wrap_int32(val)
  def to_int32(val) when is_float(val), do: wrap_int32(trunc(val))
  def to_int32(true), do: 1
  def to_int32(false), do: 0
  def to_int32(nil), do: 0
  def to_int32(:undefined), do: 0

  def to_int32(val) when is_binary(val) do
    case to_number(val) do
      n when is_integer(n) -> wrap_int32(n)
      n when is_float(n) -> wrap_int32(trunc(n))
      _ -> 0
    end
  end

  def to_int32(_), do: 0

  def to_uint32(val) when is_integer(val), do: Bitwise.band(val, 0xFFFFFFFF)
  def to_uint32(val) when is_float(val), do: Bitwise.band(trunc(val), 0xFFFFFFFF)
  def to_uint32(true), do: 1
  def to_uint32(false), do: 0
  def to_uint32(nil), do: 0
  def to_uint32(:undefined), do: 0

  def to_uint32(val) when is_binary(val) do
    case to_number(val) do
      n when is_integer(n) -> Bitwise.band(n, 0xFFFFFFFF)
      n when is_float(n) -> Bitwise.band(trunc(n), 0xFFFFFFFF)
      _ -> 0
    end
  end

  def to_uint32(_), do: 0

  defp wrap_int32(n) do
    n = Bitwise.band(n, 0xFFFFFFFF)
    if n >= 0x80000000, do: n - 0x100000000, else: n
  end

  def stringify(:undefined), do: "undefined"
  def stringify(nil), do: "null"
  def stringify(true), do: "true"
  def stringify(false), do: "false"
  def stringify(n) when is_integer(n), do: Integer.to_string(n)
  def stringify(n) when is_float(n) and n == 0.0, do: "0"
  def stringify(n) when is_float(n), do: format_float(n)
  def stringify({:bigint, n}), do: Integer.to_string(n)
  def stringify({:symbol, desc}), do: "Symbol(#{desc})"
  def stringify({:symbol, desc, _ref}), do: "Symbol(#{desc})"
  def stringify(s) when is_binary(s), do: s

  def stringify({:obj, ref} = obj) do
    data = Heap.get_obj(ref, %{})

    case data do
      list when is_list(list) ->
        Enum.map_join(list, ",", &stringify/1)

      map when is_map(map) ->
        case Map.get(map, "toString") do
          fun when fun != nil and fun != :undefined ->
            stringify(
              Interpreter.invoke_with_receiver(fun, [], QuickBEAM.BeamVM.Runtime.gas_budget(), obj)
            )

          _ ->
            "[object Object]"
        end

      _ ->
        "[object Object]"
    end
  end

  def stringify(_), do: "[object]"

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
  def typeof({:bound, _, _}), do: "function"
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
  def add(a, b) when is_binary(a) or is_binary(b), do: stringify(a) <> stringify(b)
  def add(a, b) when is_number(a) and is_number(b), do: a + b
  def add(a, b), do: numeric_add(to_number(a), to_number(b))

  defp numeric_add(a, b) when is_number(a) and is_number(b), do: a + b
  defp numeric_add(:nan, _), do: :nan
  defp numeric_add(_, :nan), do: :nan
  defp numeric_add(:infinity, :neg_infinity), do: :nan
  defp numeric_add(:neg_infinity, :infinity), do: :nan
  defp numeric_add(:infinity, _), do: :infinity
  defp numeric_add(:neg_infinity, _), do: :neg_infinity
  defp numeric_add(_, :infinity), do: :infinity
  defp numeric_add(_, :neg_infinity), do: :neg_infinity
  defp numeric_add(_, _), do: :nan

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
        if na == 0 or nb == 0, do: :nan, else: mul_inf_sign(na, nb)

      # Reached when one or both args were non-numeric but to_number made them numeric (e.g. booleans)
      is_number(na) and is_number(nb) ->
        na * nb

      true ->
        :nan
    end
  end

  defp mul_inf_sign(a, b) do
    sign_a = if a == :neg_infinity or (is_number(a) and a < 0), do: -1, else: 1
    sign_b = if b == :neg_infinity or (is_number(b) and b < 0), do: -1, else: 1
    if sign_a * sign_b > 0, do: :infinity, else: :neg_infinity
  end

  def div({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, Kernel.div(a, b)}

  def div({:bigint, _}, {:bigint, 0}),
    do: throw({:js_throw, %{"message" => "Division by zero", "name" => "RangeError"}})

  def div(a, b) when is_number(a) and is_number(b), do: div_numbers(a, b)

  def div(a, b) do
    na = to_number(a)
    nb = to_number(b)

    cond do
      na == :nan or nb == :nan ->
        :nan

      na in [:infinity, :neg_infinity] or nb in [:infinity, :neg_infinity] ->
        div_inf(na, nb)

      is_number(na) and is_number(nb) ->
        div_numbers(na, nb)

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

  defp div_numbers(a, b) when b == 0, do: if(neg_zero?(b), do: div_by_neg_zero(a), else: inf_or_nan(a))
  defp div_numbers(a, b), do: a / b

  defp div_by_neg_zero(a) when a > 0, do: :neg_infinity
  defp div_by_neg_zero(a) when a < 0, do: :infinity
  defp div_by_neg_zero(_), do: :nan

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
    short = :erlang.float_to_binary(n, [:short])

    cond do
      String.contains?(short, "e") or String.contains?(short, "E") ->
        format_js_exponential(short, n)

      String.ends_with?(short, ".0") ->
        String.trim_trailing(short, ".0")

      true ->
        short
    end
  end

  defp format_js_exponential(short, _n) do
    {mantissa, exp} =
      case String.split(short, ~r/[eE]/) do
        [m, e] -> {m, String.to_integer(e)}
        _ -> {short, 0}
      end

    mantissa =
      if String.ends_with?(mantissa, ".0"),
        do: String.trim_trailing(mantissa, ".0"),
        else: mantissa

    expand_exponential(mantissa, exp)
  end

  defp expand_exponential(mantissa, exp) when exp >= 0 and exp <= 20 do
    {prefix, digits, decimal_pos} = split_mantissa(mantissa)
    total_pos = decimal_pos + exp

    if total_pos >= String.length(digits) do
      prefix <> digits <> String.duplicate("0", total_pos - String.length(digits))
    else
      prefix <> String.slice(digits, 0, total_pos) <> "." <> String.slice(digits, total_pos..-1//1)
    end
  end

  defp expand_exponential(mantissa, exp) when exp < 0 and exp >= -6 do
    {prefix, digits, _} = split_mantissa(mantissa)
    prefix <> "0." <> String.duplicate("0", abs(exp) - 1) <> digits
  end

  defp expand_exponential(mantissa, exp) do
    sign = if exp >= 0, do: "+", else: ""
    mantissa <> "e" <> sign <> Integer.to_string(exp)
  end

  defp split_mantissa(mantissa) do
    {prefix, abs_mantissa} =
      case mantissa do
        "-" <> rest -> {"-", rest}
        other -> {"", other}
      end

    digits = String.replace(abs_mantissa, ".", "")

    decimal_pos =
      case String.split(abs_mantissa, ".") do
        [int, _] -> String.length(int)
        _ -> String.length(digits)
      end

    {prefix, digits, decimal_pos}
  end

  defp inf_or_nan(a) when a > 0, do: :infinity
  defp inf_or_nan(a) when a < 0, do: :neg_infinity
  defp inf_or_nan(_), do: :nan

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

  def shl(a, b), do: to_int32(Bitwise.bsl(to_int32(a), Bitwise.band(to_int32(b), 31)))
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

  defp abstract_eq(nil, nil), do: true
  defp abstract_eq(nil, :undefined), do: true
  defp abstract_eq(:undefined, nil), do: true
  defp abstract_eq(:undefined, :undefined), do: true
  defp abstract_eq(a, b) when is_number(a) and is_number(b), do: a == b
  defp abstract_eq(a, b) when is_binary(a) and is_binary(b), do: a == b
  defp abstract_eq(a, b) when is_boolean(a) and is_boolean(b), do: a == b
  defp abstract_eq(true, b), do: abstract_eq(1, b)
  defp abstract_eq(a, true), do: abstract_eq(a, 1)
  defp abstract_eq(false, b), do: abstract_eq(0, b)
  defp abstract_eq(a, false), do: abstract_eq(a, 0)
  defp abstract_eq(a, b) when is_number(a) and is_binary(b), do: a == to_number(b)
  defp abstract_eq(a, b) when is_binary(a) and is_number(b), do: to_number(a) == b
  defp abstract_eq({:bigint, a}, b) when is_integer(b), do: a == b
  defp abstract_eq({:bigint, a}, b) when is_float(b), do: a == b

  defp abstract_eq({:bigint, a}, b) when is_binary(b) do
    case Integer.parse(b) do
      {n, ""} -> a == n
      _ -> false
    end
  end

  defp abstract_eq(a, {:bigint, b}) when is_binary(a) do
    case Integer.parse(a) do
      {n, ""} -> n == b
      _ -> false
    end
  end

  defp abstract_eq(a, {:bigint, b}) when is_integer(a), do: a == b
  defp abstract_eq(a, {:bigint, b}) when is_float(a), do: a == b

  defp abstract_eq({:obj, _} = obj, b) when is_number(b) or is_binary(b) do
    prim = to_primitive(obj)
    if match?({:obj, _}, prim), do: false, else: abstract_eq(prim, b)
  end

  defp abstract_eq(a, {:obj, _} = obj) when is_number(a) or is_binary(a) do
    prim = to_primitive(obj)
    if match?({:obj, _}, prim), do: false, else: abstract_eq(a, prim)
  end

  defp abstract_eq({:obj, ref1}, {:obj, ref2}), do: ref1 === ref2
  defp abstract_eq(_, _), do: false

  defp to_primitive({:obj, ref} = obj) do
    data = Heap.get_obj(ref, %{})

    if is_map(data) do
      try_call_method(data, obj, "valueOf") ||
        try_proto_method(data, obj, "valueOf") ||
        try_call_method(data, obj, "toString") ||
        try_proto_method(data, obj, "toString") ||
        obj
    else
      obj
    end
  end

  defp to_primitive(val), do: val # catch-all for non-object values

  defp try_call_method(map, obj, method) do
    case Map.get(map, method) do
      {:builtin, _, cb} ->
        result = cb.([], obj)
        unless match?({:obj, _}, result), do: result

      fun when fun != nil and fun != :undefined ->
        result = Interpreter.invoke_with_receiver(fun, [], QuickBEAM.BeamVM.Runtime.gas_budget(), obj)
        unless match?({:obj, _}, result), do: result

      _ ->
        nil
    end
  end

  defp try_proto_method(map, obj, method) do
    case Map.get(map, proto()) do
      {:obj, pref} ->
        pmap = Heap.get_obj(pref, %{})
        if is_map(pmap), do: try_call_method(pmap, obj, method)

      _ ->
        nil
    end
  end

end
