defmodule QuickBEAM.VM.Interpreter.Values.Coercion do
  @moduledoc "JS type coercion: to_number, to_int32, to_uint32, to_primitive, to_string_val, and numeric parsing."

  import QuickBEAM.VM.Heap.Keys
  import QuickBEAM.VM.Value, only: [is_object: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Bytecode

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
    if is_object(prim), do: :nan, else: to_number(prim)
  end

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
  def to_number(%Bytecode.Function{} = f), do: to_number(fn_to_primitive(f))
  def to_number({:bound, _, _, _, _} = f), do: to_number(fn_to_primitive(f))
  def to_number({:builtin, _, _} = f), do: to_number(fn_to_primitive(f))
  def to_number(_), do: :nan

  def parse_numeric(""), do: 0
  def parse_numeric("0x" <> rest), do: parse_int_or_nan(rest, 16)
  def parse_numeric("0X" <> rest), do: parse_int_or_nan(rest, 16)
  def parse_numeric("0o" <> rest), do: parse_int_or_nan(rest, 8)
  def parse_numeric("0O" <> rest), do: parse_int_or_nan(rest, 8)
  def parse_numeric("0b" <> rest), do: parse_int_or_nan(rest, 2)
  def parse_numeric("0B" <> rest), do: parse_int_or_nan(rest, 2)
  def parse_numeric("Infinity" <> _), do: :infinity
  def parse_numeric("+Infinity" <> _), do: :infinity
  def parse_numeric("-Infinity" <> _), do: :neg_infinity

  def parse_numeric(s) do
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

  def parse_int_or_nan(s, base) do
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

  def wrap_int32(n) do
    n = Bitwise.band(n, 0xFFFFFFFF)
    if n >= 0x80000000, do: n - 0x100000000, else: n
  end

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
  def to_string_val({:symbol, desc}), do: "Symbol(#{desc})"
  def to_string_val({:symbol, desc, _ref}), do: "Symbol(#{desc})"
  def to_string_val(s) when is_binary(s), do: s
  def to_string_val({:closure, _, %{source: src}}) when is_binary(src) and src != "", do: src
  def to_string_val({:closure, _, _}), do: "function () { [native code] }"
  def to_string_val(%Bytecode.Function{source: src}) when is_binary(src) and src != "", do: src
  def to_string_val(%Bytecode.Function{}), do: "function () { [native code] }"
  def to_string_val({:builtin, name, _}), do: "function #{name}() { [native code] }"
  def to_string_val({:bound, _, _, _, _}), do: "function () { [native code] }"

  def to_string_val({:obj, ref} = obj) do
    data = Heap.get_obj(ref, %{})

    case data do
      {:qb_arr, arr} ->
        :array.to_list(arr)
        |> Enum.map(&to_string_val/1)
        |> Enum.join(",")

      list when is_list(list) ->
        Enum.map_join(list, ",", fn
          :undefined -> ""
          nil -> ""
          v -> to_string_val(v)
        end)

      map when is_map(map) ->
        wrapped_key =
          cond do
            Map.has_key?(map, "__wrapped_string__") -> "__wrapped_string__"
            Map.has_key?(map, "__wrapped_number__") -> "__wrapped_number__"
            Map.has_key?(map, "__wrapped_boolean__") -> "__wrapped_boolean__"
            Map.has_key?(map, "__wrapped_bigint__") -> "__wrapped_bigint__"
            Map.has_key?(map, "__wrapped_symbol__") -> "__wrapped_symbol__"
            true -> nil
          end

        cond do
          wrapped_key != nil ->
            to_string_val(Map.get(map, wrapped_key))

          (fun = Map.get(map, "toString")) != nil and fun != :undefined ->
            to_string_val(
              Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj)
            )

          true ->
            "[object Object]"
        end

      _ ->
        "[object Object]"
    end
  end

  def to_string_val(_), do: "[object]"

  def to_primitive(val) when is_number(val) or is_binary(val) or is_boolean(val) or is_atom(val),
    do: val

  def to_primitive({:bigint, _} = val), do: val

  def to_primitive({:closure, _, %{source: src}}) when is_binary(src) and src != "", do: src
  def to_primitive({:closure, _, _}), do: "function () { [native code] }"

  def to_primitive(%Bytecode.Function{source: src}) when is_binary(src) and src != "", do: src
  def to_primitive(%Bytecode.Function{}), do: "function () { [native code] }"
  def to_primitive({:builtin, name, _}), do: "function #{name}() { [native code] }"
  def to_primitive({:bound, _, _, _, _}), do: "function () { [native code] }"

  def to_primitive({:obj, ref} = obj) do
    data = Heap.get_obj(ref, %{})

    if is_map(data) do
      wrapped_key =
        cond do
          Map.has_key?(data, "__wrapped_bigint__") -> "__wrapped_bigint__"
          Map.has_key?(data, "__wrapped_number__") -> "__wrapped_number__"
          Map.has_key?(data, "__wrapped_string__") -> "__wrapped_string__"
          Map.has_key?(data, "__wrapped_boolean__") -> "__wrapped_boolean__"
          Map.has_key?(data, "__wrapped_symbol__") -> "__wrapped_symbol__"
          true -> nil
        end

      if wrapped_key != nil do
        Map.get(data, wrapped_key)
      else
        sym_key = {:symbol, "Symbol.toPrimitive"}

        raw_prim = Map.get(data, sym_key) || Get.get(obj, sym_key)

        to_prim =
          case raw_prim do
            {:accessor, getter, _} when getter != nil ->
              Get.call_getter(getter, obj)

            other ->
              other
          end

        if to_prim != nil and to_prim != :undefined do
          if not callable?(to_prim) do
            throw(
              {:js_throw, Heap.make_error("Symbol.toPrimitive is not a function", "TypeError")}
            )
          end

          result =
            Invocation.invoke_with_receiver(to_prim, ["default"], Runtime.gas_budget(), obj)

          if is_object(result) do
            throw(
              {:js_throw,
               Heap.make_error("Cannot convert object to primitive value", "TypeError")}
            )
          else
            result
          end
        else
          call_to_primitive(data, obj, "valueOf") ||
            if(not has_own_method?(data, "valueOf"),
              do: proto_to_primitive(data, obj, "valueOf")
            ) ||
            call_to_primitive(data, obj, "toString") ||
            if(not has_own_method?(data, "toString"),
              do:
                proto_to_primitive(data, obj, "toString") || get_to_primitive(obj, "toString")
            ) ||
            throw(
              {:js_throw,
               Heap.make_error("Cannot convert object to primitive value", "TypeError")}
            )
        end
      end
    else
      obj
    end
  end

  def fn_to_primitive(fun) do
    statics = Heap.get_ctor_statics(fun)
    vo = Map.get(statics, "valueOf")
    ts = Map.get(statics, "toString")

    result =
      if callable?(vo) do
        r = Invocation.invoke_with_receiver(vo, [], Runtime.gas_budget(), fun)
        if function_like?(r), do: nil, else: r
      end

    result =
      result ||
        if callable?(ts) do
          r = Invocation.invoke_with_receiver(ts, [], Runtime.gas_budget(), fun)
          if function_like?(r), do: nil, else: r
        end

    result || to_string_val(fun)
  end

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

  def coerce_to_primitive(val) do
    cond do
      is_object(val) -> to_primitive(val)
      function_like?(val) -> fn_to_primitive(val)
      true -> val
    end
  end

  defp callable?({:closure, _, _}), do: true
  defp callable?({:builtin, _, cb}) when is_function(cb), do: true
  defp callable?({:bound, _, _, _, _}), do: true
  defp callable?(%Bytecode.Function{}), do: true
  defp callable?(_), do: false

  defp function_like?({:closure, _, _}), do: true
  defp function_like?(%Bytecode.Function{}), do: true
  defp function_like?({:bound, _, _, _, _}), do: true
  defp function_like?({:builtin, _, _}), do: true
  defp function_like?(_), do: false

  defp has_own_method?(data, method) when is_map(data) do
    case Map.fetch(data, method) do
      {:ok, :undefined} -> false
      {:ok, _} -> true
      :error -> false
    end
  end

  @dialyzer {:nowarn_function, has_own_method?: 2}
  defp has_own_method?(_, _), do: false

  defp get_to_primitive(obj, method) do
    case Get.get(obj, method) do
      fun when fun != nil and fun != :undefined ->
        unwrap_primitive(Invocation.invoke_with_receiver(fun, [], Runtime.gas_budget(), obj))

      _ ->
        nil
    end
  end

  defp call_to_primitive(map, obj, method) do
    case Map.get(map, method) do
      {:builtin, _, cb} ->
        unwrap_primitive(cb.([], obj))

      fun when fun != nil and fun != :undefined ->
        if callable?(fun) do
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
