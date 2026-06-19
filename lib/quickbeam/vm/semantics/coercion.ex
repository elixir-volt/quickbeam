defmodule QuickBEAM.VM.Semantics.Coercion do
  @moduledoc "JS type coercion: to_number, to_int32, to_uint32, to_primitive, to_string_val, and numeric parsing."

  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Heap, Invocation, Runtime, Value}
  alias QuickBEAM.VM.ObjectModel.{Get, InternalMethods, WrappedPrimitive}

  @doc "Coerces a VM value using JavaScript ToNumber semantics."
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
        {:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")}
      )

  def to_number({:obj, _} = obj) do
    prim = to_primitive(obj)
    if Value.object_like?(prim), do: throw_object_to_primitive_error(), else: to_number(prim)
  end

  def to_number({:qb_arr, _} = array), do: array_to_number(array)

  def to_number({:symbol, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def to_number({:symbol, _, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )

  def to_number({:closure, _, _} = f), do: to_number(fn_to_primitive(f))
  def to_number(%QuickBEAM.VM.Function{} = f), do: to_number(fn_to_primitive(f))
  def to_number({:bound, _, _, _, _} = f), do: to_number(fn_to_primitive(f))
  def to_number({:builtin, _, _} = f), do: to_number(fn_to_primitive(f))
  def to_number(_), do: :nan

  defp array_to_number(array) do
    array
    |> QuickBEAM.VM.Runtime.ArraySource.to_list()
    |> Enum.map_join(",", &to_string_val/1)
    |> String.trim()
    |> parse_numeric()
  end

  def to_number({:obj, _} = obj, hint) do
    prim = to_primitive(obj, hint)
    if Value.object_like?(prim), do: throw_object_to_primitive_error(), else: to_number(prim)
  end

  def to_number(val, _hint), do: to_number(val)

  @doc "Coerces using Number() constructor semantics, where BigInt is accepted."
  def number_constructor_to_number({:bigint, n}), do: bigint_to_number(n)
  def number_constructor_to_number(value), do: to_number(value)

  defp bigint_to_number(n) when abs(n) <= 9_007_199_254_740_991, do: n
  defp bigint_to_number(n), do: n * 1.0

  @doc "Parses a JavaScript numeric string literal into a VM number value."
  def parse_numeric(""), do: 0
  def parse_numeric("0x" <> rest), do: parse_int_or_nan(rest, 16)
  def parse_numeric("0X" <> rest), do: parse_int_or_nan(rest, 16)
  def parse_numeric("0o" <> rest), do: parse_int_or_nan(rest, 8)
  def parse_numeric("0O" <> rest), do: parse_int_or_nan(rest, 8)
  def parse_numeric("0b" <> rest), do: parse_int_or_nan(rest, 2)
  def parse_numeric("0B" <> rest), do: parse_int_or_nan(rest, 2)
  def parse_numeric("Infinity"), do: :infinity
  def parse_numeric("+Infinity"), do: :infinity
  def parse_numeric("-Infinity"), do: :neg_infinity
  def parse_numeric("-0"), do: -0.0

  def parse_numeric(s) do
    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        parse_decimal_numeric(s)
    end
  end

  defp parse_decimal_numeric(s) do
    if Regex.match?(~r/^[+-]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][+-]?\d+)?$/, s) do
      case Float.parse(normalize_decimal_numeric(s)) do
        {f, ""} -> f
        :error -> decimal_overflow_value(s)
        _ -> :nan
      end
    else
      :nan
    end
  end

  defp decimal_overflow_value("-" <> _), do: :neg_infinity
  defp decimal_overflow_value(_), do: :infinity

  defp normalize_decimal_numeric(s) do
    s
    |> String.replace(~r/^([+-]?)\./, "\\g{1}0.")
    |> String.replace(~r/\.(?=[eE])/, ".0")
  end

  @doc "Parses an integer in a radix and returns `:nan` on invalid input."
  def parse_int_or_nan(s, base) do
    case Integer.parse(s, base) do
      {i, ""} -> i
      _ -> :nan
    end
  end

  @doc "Coerces a VM value using JavaScript ToInt32 semantics."
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

  @doc "Coerces a VM value using JavaScript ToUint32 semantics."
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

  @doc "Wraps an integer into JavaScript signed 32-bit range."
  def wrap_int32(n) do
    n = Bitwise.band(n, 0xFFFFFFFF)
    if n >= 0x80000000, do: n - 0x100000000, else: n
  end

  @doc "Coerces a VM value using JavaScript ToString semantics."
  def to_string_val(:undefined), do: "undefined"
  def to_string_val(nil), do: "null"
  def to_string_val(true), do: "true"
  def to_string_val(false), do: "false"
  def to_string_val(:nan), do: "NaN"
  def to_string_val(:infinity), do: "Infinity"
  def to_string_val(:neg_infinity), do: "-Infinity"
  def to_string_val(n) when is_integer(n), do: Integer.to_string(n)
  def to_string_val(n) when is_float(n) and n == 0.0, do: "0"
  def to_string_val(n) when is_float(n), do: format_float(n)
  def to_string_val({:bigint, n}), do: Integer.to_string(n)
  def to_string_val({:symbol, :undefined}), do: "Symbol()"
  def to_string_val({:symbol, :undefined, _ref}), do: "Symbol()"
  def to_string_val({:symbol, desc}), do: "Symbol(#{desc})"
  def to_string_val({:symbol, desc, _ref}), do: "Symbol(#{desc})"
  def to_string_val(s) when is_binary(s), do: s
  def to_string_val({:closure, _, _} = fun), do: callable_to_string_primitive(fun)
  def to_string_val(%QuickBEAM.VM.Function{} = fun), do: callable_to_string_primitive(fun)
  def to_string_val({:builtin, _, _} = fun), do: callable_to_string_primitive(fun)
  def to_string_val({:bound, _, _, _, _} = fun), do: callable_to_string_primitive(fun)

  def to_string_val({:obj, ref} = obj),
    do: object_to_string_primitive(obj, Heap.get_obj(ref, %{}))

  def to_string_val(_), do: "[object]"

  defp object_to_string_primitive(obj, data) do
    with :object <- call_string_hint_method(obj, data, "toString"),
         :object <- call_string_hint_method(obj, data, "valueOf") do
      throw({:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")})
    else
      value -> to_string_val(value)
    end
  end

  defp callable_to_string_primitive(fun) do
    with :object <- call_string_hint_method(fun, %{}, "toString"),
         :object <- call_string_hint_method(fun, %{}, "valueOf") do
      to_string_val_without_overrides(fun)
    else
      value -> to_string_val(value)
    end
  end

  defp to_string_val_without_overrides({:closure, _, %{source: src}})
       when is_binary(src) and src != "",
       do: src

  defp to_string_val_without_overrides({:closure, _, _}), do: "function () { [native code] }"

  defp to_string_val_without_overrides(%QuickBEAM.VM.Function{source: src})
       when is_binary(src) and src != "",
       do: src

  defp to_string_val_without_overrides(%QuickBEAM.VM.Function{}),
    do: "function () { [native code] }"

  defp to_string_val_without_overrides({:builtin, name, _}),
    do: "function #{name}() { [native code] }"

  defp to_string_val_without_overrides({:bound, _, _, _, _}), do: "function () { [native code] }"

  defp call_string_hint_method(obj, data, name) do
    fun =
      case primitive_wrapper_proto_method(obj, name) do
        {:ok, method} -> method
        _ -> own_or_inherited_method(obj, data, name)
      end

    if callable?(fun) do
      result = Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj)
      if Value.object_like?(result), do: :object, else: result
    else
      :object
    end
  end

  defp own_or_inherited_method(obj, data, name) when is_map(data) do
    case Map.get(data, name) do
      {:accessor, getter, _} when getter != nil -> Get.call_getter(getter, obj)
      nil -> Get.get(obj, name)
      value -> value
    end
  end

  defp own_or_inherited_method(obj, _data, name), do: Get.get(obj, name)

  @doc "Coerces an object value using JavaScript ToPrimitive semantics."
  def to_primitive(val) when is_number(val) or is_binary(val) or is_boolean(val) or is_atom(val),
    do: val

  def to_primitive({:bigint, _} = val), do: val
  def to_primitive({:symbol, _} = val), do: val
  def to_primitive({:symbol, _, _} = val), do: val

  def to_primitive({:closure, _, %{source: src}}) when is_binary(src) and src != "", do: src
  def to_primitive({:closure, _, _}), do: "function () { [native code] }"

  def to_primitive(%QuickBEAM.VM.Function{source: src}) when is_binary(src) and src != "", do: src
  def to_primitive(%QuickBEAM.VM.Function{}), do: "function () { [native code] }"
  def to_primitive({:builtin, name, _}), do: "function #{name}() { [native code] }"
  def to_primitive({:bound, _, _, _, _}), do: "function () { [native code] }"

  def to_primitive({:obj, _} = obj), do: object_to_primitive(obj, "default")

  def to_primitive({:obj, _} = obj, hint), do: object_to_primitive(obj, hint)
  def to_primitive(value, _hint), do: to_primitive(value)

  defp object_to_primitive({:obj, ref} = obj, hint) do
    data = Heap.get_obj(ref, %{})

    if is_map(data) do
      sym_key = {:symbol, "Symbol.toPrimitive"}

      raw_prim = Map.get(data, sym_key) || Get.get(obj, sym_key)

      to_prim =
        case raw_prim do
          {:accessor, getter, _} when getter != nil ->
            Get.call_getter(getter, obj)

          other ->
            other
        end

      if not Value.nullish?(to_prim) do
        if not callable?(to_prim) do
          throw({:js_throw, Heap.make_error("Symbol.toPrimitive is not a function", "TypeError")})
        end

        result = Invocation.invoke_with_receiver(to_prim, [hint], Runtime.gas_budget(), obj)

        if Value.object_like?(result) do
          throw(
            {:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")}
          )
        else
          result
        end
      else
        case ordinary_to_primitive(obj, ordinary_method_order(hint)) do
          {:ok, value} ->
            value

          :none ->
            throw(
              {:js_throw,
               Heap.make_error("Cannot convert object to primitive value", "TypeError")}
            )
        end
      end
    else
      case ordinary_to_primitive(obj, ordinary_method_order(hint)) do
        {:ok, value} -> value
        :none -> obj
      end
    end
  end

  @doc "Converts a function-like VM value to its primitive string representation."
  def fn_to_primitive(fun) do
    statics = Heap.get_ctor_statics(fun)
    vo = Map.get(statics, "valueOf")
    ts = Map.get(statics, "toString")

    result =
      if callable?(vo) do
        r = Invocation.invoke_with_receiver(vo, [], Runtime.gas_budget(), fun)
        if Value.function_like?(r), do: nil, else: r
      end

    result =
      result ||
        if callable?(ts) do
          r = Invocation.invoke_with_receiver(ts, [], Runtime.gas_budget(), fun)
          if Value.function_like?(r), do: nil, else: r
        end

    result || to_string_val(fun)
  end

  @doc "Coerces a VM value using JavaScript ToNumeric semantics."
  def to_numeric({:obj, _} = obj) do
    case to_primitive(obj) do
      {:bigint, _} = b ->
        b

      {:obj, _} ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")}
        )

      other ->
        to_number(other)
    end
  end

  @doc "Compatibility wrapper for primitive coercion."
  def coerce_to_primitive(val) do
    cond do
      is_object(val) -> to_primitive(val)
      Value.function_like?(val) -> fn_to_primitive(val)
      true -> val
    end
  end

  defp callable?({:builtin, _, cb}) when not is_function(cb), do: false
  defp callable?(value), do: Value.function_like?(value)

  defp throw_object_to_primitive_error do
    throw({:js_throw, Heap.make_error("Cannot convert object to primitive value", "TypeError")})
  end

  defp ordinary_method_order("string"), do: ["toString", "valueOf"]
  defp ordinary_method_order(_hint), do: ["valueOf", "toString"]

  defp ordinary_to_primitive(_obj, []), do: :none

  defp ordinary_to_primitive(obj, [method | rest]) do
    case get_to_primitive(obj, method) do
      {:ok, value} -> {:ok, value}
      :none -> ordinary_to_primitive(obj, rest)
    end
  end

  defp get_to_primitive(obj, method) do
    case primitive_wrapper_proto_method(obj, method) do
      {:ok, fun} ->
        invoke_primitive_method(fun, obj)

      :none ->
        :none

      :missing ->
        invoke_primitive_method(Get.get(obj, method), obj)
    end
  end

  defp invoke_primitive_method(fun, obj) when not is_nil(fun) and fun != :undefined do
    if callable?(fun) do
      unwrap_primitive(Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj))
    else
      :none
    end
  end

  defp invoke_primitive_method(_fun, _obj), do: :none

  defp primitive_wrapper_proto_method({:obj, ref} = obj, method) do
    data = Heap.get_obj(ref, %{})

    with true <- primitive_wrapper?(data),
         {:obj, _} = proto <- InternalMethods.get_prototype_of(obj),
         {:obj, _} = desc <- InternalMethods.own_property(proto, method) do
      getter = Get.get(desc, "get")
      value = Get.get(desc, "value")

      cond do
        not Value.nullish?(getter) -> {:ok, Get.call_getter(getter, obj)}
        value != :undefined -> {:ok, value}
        true -> :none
      end
    else
      false -> :missing
      _ -> :missing
    end
  end

  defp primitive_wrapper_proto_method(_obj, _method), do: :missing

  defp primitive_wrapper?(data),
    do: WrappedPrimitive.type?(data, :symbol) or WrappedPrimitive.type?(data, :bigint)

  defp unwrap_primitive(val) do
    if Value.object_like?(val), do: :none, else: {:ok, val}
  end

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
end
