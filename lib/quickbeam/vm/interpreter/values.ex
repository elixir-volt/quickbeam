defmodule QuickBEAM.VM.Interpreter.Values do
  @moduledoc false
  import QuickBEAM.VM.Heap.Keys

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime

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

  alias QuickBEAM.VM.Bytecode
  import Bitwise, except: [band: 2, bor: 2, bxor: 2, bnot: 1]

  def truthy?(nil), do: false
  def truthy?(:undefined), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(-0.0), do: false
  def truthy?(:nan), do: false
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

  def to_number({:obj, _} = obj) do
    prim = to_primitive(obj)
    if match?({:obj, _}, prim), do: :nan, else: to_number(prim)
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
      {i, ""} ->
        i

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

  def to_int32(:nan), do: 0
  def to_int32(:infinity), do: 0
  def to_int32(:neg_infinity), do: 0
  def to_int32({:obj, _} = obj), do: to_int32(to_number(obj))
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

  def to_uint32(:nan), do: 0
  def to_uint32(:infinity), do: 0
  def to_uint32(:neg_infinity), do: 0
  def to_uint32({:obj, _} = obj), do: to_uint32(to_number(obj))
  def to_uint32(_), do: 0

  defp wrap_int32(n) do
    n = Bitwise.band(n, 0xFFFFFFFF)
    if n >= 0x80000000, do: n - 0x100000000, else: n
  end

  def stringify(:undefined), do: "undefined"
  def stringify(nil), do: "null"
  def stringify(true), do: "true"
  def stringify(false), do: "false"
  def stringify(:nan), do: "NaN"
  def stringify(:infinity), do: "Infinity"
  def stringify(:neg_infinity), do: "-Infinity"
  def stringify(n) when is_integer(n), do: Integer.to_string(n)
  def stringify(n) when is_float(n) and n == 0.0, do: "0"
  def stringify(n) when is_float(n), do: format_float(n)
  def stringify({:bigint, n}), do: Integer.to_string(n)
  def stringify({:symbol, desc}), do: "Symbol(#{desc})"
  def stringify({:symbol, desc, _ref}), do: "Symbol(#{desc})"
  def stringify(s) when is_binary(s), do: s
  def stringify({:closure, _, %{source: src}}) when is_binary(src) and src != "", do: src
  def stringify({:closure, _, _}), do: "function () { [native code] }"
  def stringify(%Bytecode.Function{source: src}) when is_binary(src) and src != "", do: src
  def stringify(%Bytecode.Function{}), do: "function () { [native code] }"
  def stringify({:builtin, name, _}), do: "function #{name}() { [native code] }"
  def stringify({:bound, _, _, _, _}), do: "function () { [native code] }"

  def stringify({:obj, ref} = obj) do
    data = Heap.get_obj(ref, %{})

    case data do
      {:qb_arr, arr} ->
        :array.to_list(arr)
        |> Enum.map(&stringify/1)
        |> Enum.join(",")

      list when is_list(list) ->
        Enum.map_join(list, ",", fn
          :undefined -> ""
          nil -> ""
          v -> stringify(v)
        end)

      map when is_map(map) ->
        wrapped = Map.get(map, "__wrapped_string__") ||
          Map.get(map, "__wrapped_number__") ||
          Map.get(map, "__wrapped_boolean__") ||
          Map.get(map, "__wrapped_bigint__")

        cond do
          wrapped != nil ->
            stringify(wrapped)

          (fun = Map.get(map, "toString")) != nil and fun != :undefined ->
            stringify(Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj))

          true ->
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
  def typeof(:neg_infinity), do: "number"
  def typeof(nil), do: "object"
  def typeof(true), do: "boolean"
  def typeof(false), do: "boolean"
  def typeof(val) when is_number(val), do: "number"
  def typeof(val) when is_binary(val), do: "string"
  def typeof(%Bytecode.Function{}), do: "function"
  def typeof({:closure, _, %Bytecode.Function{}}), do: "function"
  def typeof({:symbol, _}), do: "symbol"
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:bound, _, _, _, _}), do: "function"
  def typeof({:bigint, _}), do: "bigint"
  def typeof({:builtin, _, map}) when is_map(map), do: "object"
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

  def add({:symbol, _}, _),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add(_, {:symbol, _}),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add({:symbol, _, _}, _),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add(_, {:symbol, _, _}),
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot convert a Symbol value to a string",
           "TypeError"
         )}
      )

  def add(a, b) when is_binary(a) or is_binary(b), do: stringify(a) <> stringify(b)
  def add(a, b) when is_number(a) and is_number(b), do: safe_add(a, b)

  def add({:obj, _} = a, b) do
    pa = to_primitive(a)
    pb = if match?({:obj, _}, b), do: to_primitive(b), else: b

    if match?({:obj, _}, pa) or match?({:obj, _}, pb) do
      stringify(pa) <> stringify(pb)
    else
      add(pa, pb)
    end
  end

  def add(a, {:obj, _} = b) do
    pb = to_primitive(b)

    if match?({:obj, _}, pb) do
      stringify(a) <> stringify(pb)
    else
      add(a, pb)
    end
  end

  def add({:bigint, _}, _), do: throw_bigint_mix_error()
  def add(_, {:bigint, _}), do: throw_bigint_mix_error()
  def add({:closure, _, _} = a, b), do: add(fn_to_primitive(a), b)
  def add(a, {:closure, _, _} = b), do: add(a, fn_to_primitive(b))
  def add(%Bytecode.Function{} = a, b), do: add(fn_to_primitive(a), b)
  def add(a, %Bytecode.Function{} = b), do: add(a, fn_to_primitive(b))
  def add({:bound, _, _, _, _} = a, b), do: add(fn_to_primitive(a), b)
  def add(a, {:bound, _, _, _, _} = b), do: add(a, fn_to_primitive(b))
  def add({:builtin, _, _} = a, b), do: add(fn_to_primitive(a), b)
  def add(a, {:builtin, _, _} = b), do: add(a, fn_to_primitive(b))
  def add(a, b), do: numeric_add(to_number(a), to_number(b))

  defp numeric_add(a, b) when is_number(a) and is_number(b), do: safe_add(a, b)
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
  def sub({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def sub(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def sub({:obj, _} = a, b), do: sub(to_numeric(a), b)
  def sub(a, {:obj, _} = b), do: sub(a, to_numeric(b))
  def sub({:bigint, _}, _), do: throw_bigint_mix_error()
  def sub(_, {:bigint, _}), do: throw_bigint_mix_error()
  def sub(a, b) when is_number(a) and is_number(b), do: safe_add(a, -b)
  def sub(a, b), do: numeric_add(to_number(a), neg(to_number(b)))

  def mul({:bigint, a}, {:bigint, b}), do: {:bigint, a * b}
  def mul({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def mul(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def mul({:obj, _} = a, b), do: mul(to_numeric(a), b)
  def mul(a, {:obj, _} = b), do: mul(a, to_numeric(b))
  def mul({:bigint, _}, _), do: throw_bigint_mix_error()
  def mul(_, {:bigint, _}), do: throw_bigint_mix_error()
  def mul(a, b) when is_number(a) and is_number(b), do: safe_mul(a, b)

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

  def js_div({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, Kernel.div(a, b)}

  def js_div({:bigint, _}, {:bigint, 0}),
    do: throw({:js_throw, Heap.make_error("Division by zero", "RangeError")})

  def js_div({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def js_div(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def js_div({:obj, _} = a, b), do: js_div(to_numeric(a), b)
  def js_div(a, {:obj, _} = b), do: js_div(a, to_numeric(b))
  def js_div({:bigint, _}, _), do: throw_bigint_mix_error()
  def js_div(_, {:bigint, _}), do: throw_bigint_mix_error()
  def js_div(a, b) when is_number(a) and is_number(b), do: div_numbers(a, b)

  def js_div(a, b) do
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
  defp div_inf(:infinity, n) when is_number(n), do: if(neg_sign?(n), do: :neg_infinity, else: :infinity)
  defp div_inf(:neg_infinity, n) when is_number(n), do: if(neg_sign?(n), do: :infinity, else: :neg_infinity)
  defp div_inf(n, :infinity) when is_number(n), do: if(n < 0, do: -0.0, else: 0.0)
  defp div_inf(n, :neg_infinity) when is_number(n), do: if(n < 0, do: 0.0, else: -0.0)
  defp div_inf(_, _), do: :nan

  defp div_numbers(a, b) when b == 0,
    do: if(neg_zero?(b), do: div_by_neg_zero(a), else: inf_or_nan(a))

  defp div_numbers(a, b) do
    try do
      a / b
    rescue
      ArithmeticError ->
        if (a > 0 and b > 0) or (a < 0 and b < 0), do: :infinity, else: :neg_infinity
    end
  end

  defp div_by_neg_zero(a) when a > 0, do: :neg_infinity
  defp div_by_neg_zero(a) when a < 0, do: :infinity
  defp div_by_neg_zero(_), do: :nan

  def mod({:bigint, a}, {:bigint, b}) when b != 0, do: {:bigint, rem(a, b)}

  def mod({:bigint, _}, {:bigint, 0}),
    do: throw({:js_throw, Heap.make_error("Division by zero", "RangeError")})

  def mod({:bigint, _}, b) when is_number(b), do: throw_bigint_mix_error()
  def mod(a, {:bigint, _}) when is_number(a), do: throw_bigint_mix_error()
  def mod({:obj, _} = a, b), do: mod(to_numeric(a), b)
  def mod(a, {:obj, _} = b), do: mod(a, to_numeric(b))
  def mod({:bigint, _}, _), do: throw_bigint_mix_error()
  def mod(_, {:bigint, _}), do: throw_bigint_mix_error()

  def mod(a, b) when is_integer(a) and is_integer(b) and b != 0, do: rem(a, b)
  def mod(a, b) when is_number(a) and is_number(b) and b != 0, do: safe_arith(fn -> a - Float.floor(a / b) * b end)
  def mod(a, b) when is_number(a) and is_number(b), do: :nan
  def mod(a, b), do: numeric_mod(to_number(a), to_number(b))

  defp numeric_mod(:nan, _), do: :nan
  defp numeric_mod(_, :nan), do: :nan
  defp numeric_mod(:infinity, _), do: :nan
  defp numeric_mod(:neg_infinity, _), do: :nan
  defp numeric_mod(a, :infinity) when is_number(a), do: a
  defp numeric_mod(a, :neg_infinity) when is_number(a), do: a
  defp numeric_mod(_, b) when is_number(b) and b == 0, do: :nan
  defp numeric_mod(a, b) when is_integer(a) and is_integer(b), do: rem(a, b)
  defp numeric_mod(a, b) when is_number(a) and is_number(b) do
    try do
      a - Float.floor(a / b) * b
    rescue
      ArithmeticError -> :nan
    end
  end
  defp numeric_mod(_, _), do: :nan

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
  defp neg_sign?(n), do: n < 0 or neg_zero?(n)

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
      prefix <>
        String.slice(digits, 0, total_pos) <> "." <> String.slice(digits, total_pos..-1//1)
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
  def band({:obj, _} = a, b), do: band(to_numeric(a), b)
  def band(a, {:obj, _} = b), do: band(a, to_numeric(b))
  def band({:bigint, _}, _), do: throw_bigint_mix_error()
  def band(_, {:bigint, _}), do: throw_bigint_mix_error()
  def band(a, b), do: Bitwise.band(to_int32(a), to_int32(b))
  def bor({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bor(a, b)}
  def bor({:obj, _} = a, b), do: bor(to_numeric(a), b)
  def bor(a, {:obj, _} = b), do: bor(a, to_numeric(b))
  def bor({:bigint, _}, _), do: throw_bigint_mix_error()
  def bor(_, {:bigint, _}), do: throw_bigint_mix_error()
  def bor(a, b), do: Bitwise.bor(to_int32(a), to_int32(b))
  def bxor({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bxor(a, b)}
  def bxor({:obj, _} = a, b), do: bxor(to_numeric(a), b)
  def bxor(a, {:obj, _} = b), do: bxor(a, to_numeric(b))
  def bxor({:bigint, _}, _), do: throw_bigint_mix_error()
  def bxor(_, {:bigint, _}), do: throw_bigint_mix_error()
  def bxor(a, b), do: Bitwise.bxor(to_int32(a), to_int32(b))

  def bnot({:bigint, a}), do: {:bigint, -(a + 1)}
  def bnot({:obj, _} = a), do: bnot(to_numeric(a))
  def bnot(a), do: to_int32(Bitwise.bnot(to_int32(a)))

  def shl({:bigint, a}, {:bigint, b}) when b >= 0 and b <= 1_000_000,
    do: {:bigint, Bitwise.bsl(a, b)}

  def shl({:bigint, a}, {:bigint, b}) when b < 0,
    do: {:bigint, Bitwise.bsr(a, -b)}

  def shl({:bigint, _}, {:bigint, _}),
    do: throw({:js_throw, Heap.make_error("Maximum BigInt size exceeded", "RangeError")})

  def shl({:obj, _} = a, b), do: shl(to_numeric(a), b)
  def shl(a, {:obj, _} = b), do: shl(a, to_numeric(b))
  def shl({:bigint, _}, _), do: throw_bigint_mix_error()
  def shl(_, {:bigint, _}), do: throw_bigint_mix_error()
  def shl(a, b), do: to_int32(Bitwise.bsl(to_int32(a), Bitwise.band(to_int32(b), 31)))

  def sar({:bigint, a}, {:bigint, b}), do: {:bigint, Bitwise.bsr(a, b)}
  def sar({:obj, _} = a, b), do: sar(to_numeric(a), b)
  def sar(a, {:obj, _} = b), do: sar(a, to_numeric(b))
  def sar({:bigint, _}, _), do: throw_bigint_mix_error()
  def sar(_, {:bigint, _}), do: throw_bigint_mix_error()
  def sar(a, b), do: Bitwise.bsr(to_int32(a), Bitwise.band(to_int32(b), 31))

  def shr({:bigint, _}, _), do: throw({:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")})
  def shr(_, {:bigint, _}), do: throw({:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")})
  def shr({:obj, _} = a, b), do: shr(to_numeric(a), b)
  def shr(a, {:obj, _} = b), do: shr(a, to_numeric(b))

  def shr(a, b) do
    ua = to_int32(a) &&& 0xFFFFFFFF
    Bitwise.bsr(ua, Bitwise.band(to_int32(b), 31))
  end

  def lt({:bigint, a}, {:bigint, b}), do: a < b
  def lt({:bigint, _}, :nan), do: false
  def lt(:nan, {:bigint, _}), do: false
  def lt({:bigint, _}, :infinity), do: true
  def lt({:bigint, _}, :neg_infinity), do: false
  def lt(:infinity, {:bigint, _}), do: false
  def lt(:neg_infinity, {:bigint, _}), do: true
  def lt({:bigint, a}, b) when is_number(b), do: a < b
  def lt(a, {:bigint, b}) when is_number(a), do: a < b
  def lt({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.</2)
  def lt(a, {:bigint, _} = b) when is_binary(a), do: bigint_string_compare(b, a, fn x, y -> y < x end)
  def lt({:bigint, a}, b) when is_boolean(b), do: a < to_number(b)
  def lt(a, {:bigint, b}) when is_boolean(a), do: to_number(a) < b
  def lt(a, b) when is_number(a) and is_number(b), do: a < b
  def lt(a, b) when is_binary(a) and is_binary(b), do: a < b
  def lt(a, b), do: numeric_compare(to_number(a), to_number(b), &Kernel.</2)

  def lte({:bigint, a}, {:bigint, b}), do: a <= b
  def lte({:bigint, _}, :nan), do: false
  def lte(:nan, {:bigint, _}), do: false
  def lte({:bigint, _}, :infinity), do: true
  def lte({:bigint, _}, :neg_infinity), do: false
  def lte(:infinity, {:bigint, _}), do: false
  def lte(:neg_infinity, {:bigint, _}), do: true
  def lte({:bigint, a}, b) when is_number(b), do: a <= b
  def lte(a, {:bigint, b}) when is_number(a), do: a <= b
  def lte({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.<=/2)
  def lte({:bigint, a}, b) when is_boolean(b), do: a <= to_number(b)
  def lte(a, {:bigint, b}) when is_boolean(a), do: to_number(a) <= b
  def lte(a, {:bigint, _} = b) when is_binary(a), do: bigint_string_compare(b, a, fn x, y -> y <= x end)
  def lte(a, b) when is_number(a) and is_number(b), do: a <= b
  def lte(a, b) when is_binary(a) and is_binary(b), do: a <= b
  def lte(a, b), do: numeric_compare(to_number(a), to_number(b), &Kernel.<=/2)

  def gt({:bigint, a}, {:bigint, b}), do: a > b
  def gt({:bigint, _}, :nan), do: false
  def gt(:nan, {:bigint, _}), do: false
  def gt({:bigint, _}, :infinity), do: false
  def gt({:bigint, _}, :neg_infinity), do: true
  def gt(:infinity, {:bigint, _}), do: true
  def gt(:neg_infinity, {:bigint, _}), do: false
  def gt({:bigint, a}, b) when is_number(b), do: a > b
  def gt(a, {:bigint, b}) when is_number(a), do: a > b
  def gt({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.>/2)
  def gt({:bigint, a}, b) when is_boolean(b), do: a > to_number(b)
  def gt(a, {:bigint, b}) when is_boolean(a), do: to_number(a) > b
  def gt(a, {:bigint, _} = b) when is_binary(a), do: bigint_string_compare(b, a, fn x, y -> y > x end)
  def gt(a, b) when is_number(a) and is_number(b), do: a > b
  def gt(a, b) when is_binary(a) and is_binary(b), do: a > b
  def gt(a, b), do: numeric_compare(to_number(a), to_number(b), &Kernel.>/2)

  def gte({:bigint, a}, {:bigint, b}), do: a >= b
  def gte({:bigint, _}, :nan), do: false
  def gte(:nan, {:bigint, _}), do: false
  def gte({:bigint, _}, :infinity), do: false
  def gte({:bigint, _}, :neg_infinity), do: true
  def gte(:infinity, {:bigint, _}), do: true
  def gte(:neg_infinity, {:bigint, _}), do: false
  def gte({:bigint, a}, b) when is_number(b), do: a >= b
  def gte(a, {:bigint, b}) when is_number(a), do: a >= b
  def gte({:bigint, _} = a, b) when is_binary(b), do: bigint_string_compare(a, b, &Kernel.>=/2)
  def gte({:bigint, a}, b) when is_boolean(b), do: a >= to_number(b)
  def gte(a, {:bigint, b}) when is_boolean(a), do: to_number(a) >= b
  def gte(a, {:bigint, _} = b) when is_binary(a), do: bigint_string_compare(b, a, fn x, y -> y >= x end)
  def gte(a, b) when is_number(a) and is_number(b), do: a >= b
  def gte(a, b) when is_binary(a) and is_binary(b), do: a >= b
  def gte(a, b), do: numeric_compare(to_number(a), to_number(b), &Kernel.>=/2)

  defp to_numeric({:obj, _} = obj) do
    case to_primitive(obj) do
      {:bigint, _} = b -> b
      {:obj, _} -> throw({:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")})
      other -> to_number(other)
    end
  end

  defp safe_arith(fun) do
    try do
      fun.()
    rescue
      ArithmeticError -> :infinity
    end
  end

  defp safe_mul(a, b) do
    try do
      a * b
    rescue
      ArithmeticError ->
        if (a > 0 and b > 0) or (a < 0 and b < 0), do: :infinity, else: :neg_infinity
    end
  end

  defp safe_add(a, b) do
    try do
      a + b
    rescue
      ArithmeticError ->
        if a > 0 or b > 0, do: :infinity, else: :neg_infinity
    end
  end

  defp throw_bigint_mix_error do
    throw({:js_throw, Heap.make_error("Cannot mix BigInt and other types, use explicit conversions", "TypeError")})
  end

  defp bigint_string_compare({:bigint, a}, str, op) do
    case Integer.parse(str) do
      {n, ""} -> op.(a, n)
      _ -> false
    end
  end

  defp numeric_compare(:nan, _, _), do: false
  defp numeric_compare(_, :nan, _), do: false
  defp numeric_compare(:infinity, :infinity, op), do: op.(1, 1)
  defp numeric_compare(:neg_infinity, :neg_infinity, op), do: op.(1, 1)
  defp numeric_compare(:infinity, _, op), do: op.(1, 0)
  defp numeric_compare(_, :infinity, op), do: op.(0, 1)
  defp numeric_compare(:neg_infinity, _, op), do: op.(0, 1)
  defp numeric_compare(_, :neg_infinity, op), do: op.(1, 0)
  defp numeric_compare(a, b, op) when is_number(a) and is_number(b), do: op.(a, b)
  defp numeric_compare(_, _, _), do: false

  def eq({:bigint, a}, {:bigint, b}), do: a == b
  def eq(a, b), do: abstract_eq(a, b)
  def neq(a, b), do: not abstract_eq(a, b)

  defp abstract_eq(nil, nil), do: true
  defp abstract_eq(nil, :undefined), do: true
  defp abstract_eq(:undefined, nil), do: true
  defp abstract_eq(:undefined, :undefined), do: true
  defp abstract_eq(:nan, _), do: false
  defp abstract_eq(_, :nan), do: false
  defp abstract_eq(:infinity, :infinity), do: true
  defp abstract_eq(:neg_infinity, :neg_infinity), do: true
  defp abstract_eq(:infinity, b) when is_number(b), do: false
  defp abstract_eq(:neg_infinity, b) when is_number(b), do: false
  defp abstract_eq(a, :infinity) when is_number(a), do: false
  defp abstract_eq(a, :neg_infinity) when is_number(a), do: false
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
    case String.trim(b) do
      "" -> a == 0
      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} -> a == n
          _ -> false
        end
    end
  end

  defp abstract_eq(a, {:bigint, b}) when is_binary(a) do
    case String.trim(a) do
      "" -> 0 == b
      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} -> n == b
          _ -> false
        end
    end
  end

  defp abstract_eq(a, {:bigint, b}) when is_integer(a), do: a == b
  defp abstract_eq(a, {:bigint, b}) when is_float(a), do: a == b
  defp abstract_eq({:bigint, _} = a, b) when is_boolean(b), do: abstract_eq(a, to_number(b))
  defp abstract_eq(a, {:bigint, _} = b) when is_boolean(a), do: abstract_eq(to_number(a), b)

  defp abstract_eq({:obj, _} = obj, b) when is_number(b) or is_binary(b) do
    prim = to_primitive(obj)
    if match?({:obj, _}, prim), do: false, else: abstract_eq(prim, b)
  end

  defp abstract_eq(a, {:obj, _} = obj) when is_number(a) or is_binary(a) do
    prim = to_primitive(obj)
    if match?({:obj, _}, prim), do: false, else: abstract_eq(a, prim)
  end

  defp abstract_eq({:obj, ref1}, {:obj, ref2}), do: ref1 === ref2
  defp abstract_eq({:symbol, _, ref1}, {:symbol, _, ref2}), do: ref1 === ref2
  defp abstract_eq(_, _), do: false

  defp to_primitive(val) when is_number(val) or is_binary(val) or is_boolean(val) or is_atom(val), do: val
  defp to_primitive({:bigint, _} = val), do: val

  defp to_primitive({:closure, _, %{source: src}}) when is_binary(src) and src != "", do: src
  defp to_primitive({:closure, _, _}), do: "function () { [native code] }"
  defp to_primitive(%QuickBEAM.VM.Bytecode.Function{source: src}) when is_binary(src) and src != "", do: src
  defp to_primitive(%QuickBEAM.VM.Bytecode.Function{}), do: "function () { [native code] }"
  defp to_primitive({:builtin, name, _}), do: "function #{name}() { [native code] }"
  defp to_primitive({:bound, _, _, _, _}), do: "function () { [native code] }"

  defp to_primitive({:obj, ref} = obj) do
    data = Heap.get_obj(ref, %{})

    if is_map(data) do
      # Check for wrapped primitives (Object(1n), Object("str"), etc.)
      wrapped = Map.get(data, "__wrapped_bigint__") ||
        Map.get(data, "__wrapped_number__") ||
        Map.get(data, "__wrapped_string__") ||
        Map.get(data, "__wrapped_boolean__")

      if wrapped != nil do
        wrapped
      else
        # Check @@toPrimitive first (spec: 7.1.1)
        sym_key = {:symbol, "Symbol.toPrimitive"}
        toPrim = Map.get(data, sym_key) || Get.get(obj, sym_key)

        if toPrim != nil and toPrim != :undefined do
          if not is_callable?(toPrim) do
            throw({:js_throw, Heap.make_error("Symbol.toPrimitive is not a function", "TypeError")})
          end

          result = Invocation.invoke_with_receiver(toPrim, ["default"], Runtime.gas_budget(), obj)
          if match?({:obj, _}, result) do
            throw({:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")})
          else
            result
          end
        else
          call_to_primitive(data, obj, "valueOf") ||
            (if not has_own_method?(data, "valueOf"), do: proto_to_primitive(data, obj, "valueOf")) ||
            call_to_primitive(data, obj, "toString") ||
            (if not has_own_method?(data, "toString"), do: proto_to_primitive(data, obj, "toString") || get_to_primitive(obj, "toString")) ||
            throw({:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")})
        end
      end
    else
      obj
    end
  end

  defp is_callable?({:closure, _, _}), do: true
  defp is_callable?({:builtin, _, cb}) when is_function(cb), do: true
  defp is_callable?({:bound, _, _, _, _}), do: true
  defp is_callable?(%Bytecode.Function{}), do: true
  defp is_callable?(_), do: false

  defp is_function_like?({:closure, _, _}), do: true
  defp is_function_like?(%Bytecode.Function{}), do: true
  defp is_function_like?({:bound, _, _, _, _}), do: true
  defp is_function_like?({:builtin, _, _}), do: true
  defp is_function_like?(_), do: false

  defp fn_to_primitive(fun) do
    statics = Heap.get_ctor_statics(fun)
    vo = Map.get(statics, "valueOf")
    ts = Map.get(statics, "toString")

    result =
      if is_callable?(vo) do
        r = Invocation.invoke_with_receiver(vo, [], Runtime.gas_budget(), fun)
        if is_function_like?(r), do: nil, else: r
      end

    result = result ||
      if is_callable?(ts) do
        r = Invocation.invoke_with_receiver(ts, [], Runtime.gas_budget(), fun)
        if is_function_like?(r), do: nil, else: r
      end

    result || stringify(fun)
  end

  defp has_own_method?(data, method) when is_map(data) do
    case Map.get(data, method) do
      nil -> false
      :undefined -> false
      val -> is_callable?(val)
    end
  end

  defp has_own_method?(_, _), do: false

  defp get_to_primitive(obj, method) do
    case Get.get(obj, method) do
      fun when fun != nil and fun != :undefined ->
        unwrap_primitive(Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj))
      _ -> nil
    end
  end

  defp call_to_primitive(map, obj, method) do
    case Map.get(map, method) do
      {:builtin, _, cb} ->
        unwrap_primitive(cb.([], obj))

      fun when fun != nil and fun != :undefined ->
        if is_callable?(fun) do
          unwrap_primitive(Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj))
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp proto_to_primitive(map, obj, method) do
    case Map.get(map, proto()) do
      {:obj, pref} ->
        pmap = Heap.get_obj(pref, %{})
        if is_map(pmap), do: call_to_primitive(pmap, obj, method)

      _ ->
        nil
    end
  end

  defp unwrap_primitive({:obj, _}), do: nil
  defp unwrap_primitive(val), do: val
end
