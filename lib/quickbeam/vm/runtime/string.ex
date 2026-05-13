defmodule QuickBEAM.VM.Runtime.String do
  @moduledoc "String.prototype methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Builtin, Heap, Invocation}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Interpreter.Values.Coercion
  alias QuickBEAM.VM.ObjectModel.{Get, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.RegExp

  # ── Dispatch ──

  proto "charAt" do
    char_at(coerce_string_this(this), args)
  end

  proto "charCodeAt" do
    char_code_at(coerce_string_this(this), args)
  end

  proto "codePointAt" do
    code_point_at(coerce_string_this(this), args)
  end

  proto "indexOf" do
    index_of(coerce_string_this(this), args)
  end

  proto "lastIndexOf" do
    last_index_of(coerce_string_this(this), args)
  end

  proto "includes" do
    includes(coerce_string_this(this), args)
  end

  proto "startsWith" do
    starts_with(coerce_string_this(this), args)
  end

  proto "endsWith" do
    ends_with(coerce_string_this(this), args)
  end

  proto "slice" do
    slice(coerce_string_this(this), args)
  end

  proto "substring" do
    substring(coerce_string_this(this), args)
  end

  proto "substr" do
    substr(coerce_string_this(this), args)
  end

  proto "split" do
    split_dispatch(this, args)
  end

  proto "trim" do
    String.trim(coerce_string_this(this))
  end

  proto "trimStart" do
    String.trim_leading(coerce_string_this(this))
  end

  proto "trimEnd" do
    String.trim_trailing(coerce_string_this(this))
  end

  proto "toUpperCase" do
    s = coerce_string_this(this)
    :string.uppercase(s) |> IO.iodata_to_binary()
  end

  proto "toLowerCase" do
    s = coerce_string_this(this)
    locale_lowercase(s)
  end

  proto "toLocaleLowerCase" do
    s = coerce_string_this(this)
    locale_lowercase(s)
  end

  proto "toLocaleUpperCase" do
    s = coerce_string_this(this)
    :string.uppercase(s) |> IO.iodata_to_binary()
  end

  proto "repeat" do
    repeat(coerce_string_this(this), args)
  end

  proto "padStart" do
    pad(coerce_string_this(this), args, :start)
  end

  proto "padEnd" do
    pad(coerce_string_this(this), args, :end)
  end

  proto "replace" do
    replace(this, args)
  end

  proto "replaceAll" do
    replace_all(this, args)
  end

  proto "match" do
    match(coerce_string_this(this), args)
  end

  proto "matchAll" do
    match_all(coerce_string_this(this), args)
  end

  proto "localeCompare" do
    s = coerce_string_this(this)
    other = arg(args, 0, :undefined)
    other_str = if is_binary(other), do: other, else: Runtime.stringify(other)
    comparable = locale_compare_key(s)
    other_comparable = locale_compare_key(other_str)

    cond do
      comparable < other_comparable -> -1
      comparable > other_comparable -> 1
      true -> 0
    end
  end

  proto "search" do
    search(coerce_string_this(this), args)
  end

  proto "normalize" do
    normalize_string(coerce_string_this(this), args)
  end

  proto "concat" do
    coerce_string_this(this) <> Enum.map_join(args, &Runtime.stringify/1)
  end

  proto "toString" do
    unwrap_string(this)
  end

  proto "valueOf" do
    unwrap_string(this)
  end

  proto "at" do
    string_at(coerce_string_this(this), args)
  end

  proto "isWellFormed" do
    s = coerce_string_this(this)
    not has_lone_surrogate?(s)
  end

  proto "toWellFormed" do
    s = coerce_string_this(this)
    replace_lone_surrogates(s)
  end

  proto {:symbol, "Symbol.iterator"} do
    this
    |> coerce_string_this()
    |> String.codepoints()
    |> iterator_from()
  end

  # ── Implementations ──

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
  def utf16_length(string) when is_binary(string) do
    if byte_size(string) == String.length(string) do
      byte_size(string)
    else
      string
      |> String.to_charlist()
      |> Enum.reduce(0, fn cp, acc ->
        if cp > 0xFFFF, do: acc + 2, else: acc + 1
      end)
    end
  end

  @doc "Returns the string value for a JavaScript UTF-16 code-unit index."
  def utf16_code_unit_at(_string, index) when index < 0, do: :undefined

  def utf16_code_unit_at(string, index) when is_binary(string) do
    string
    |> utf16_code_units()
    |> Enum.at(index, :undefined)
  end

  @doc "Returns enumerable string index/value pairs using JavaScript UTF-16 indexing."
  def utf16_indexed_entries(string) when is_binary(string) do
    string
    |> utf16_code_units()
    |> Enum.with_index()
    |> Enum.map(fn {char, index} -> {Integer.to_string(index), char} end)
  end

  def utf16_code_units(string) when is_binary(string) do
    string
    |> utf16_code_unit_values()
    |> Enum.map(&surrogate_or_utf8/1)
  end

  def utf16_code_unit_values(string) when is_binary(string) do
    do_utf16_code_unit_values(string, [])
  end

  defp do_utf16_code_unit_values(<<>>, acc), do: Enum.reverse(acc)

  defp do_utf16_code_unit_values(<<cp, rest::binary>>, acc) when cp < 0x80,
    do: do_utf16_code_unit_values(rest, [cp | acc])

  defp do_utf16_code_unit_values(<<b1, b2, rest::binary>>, acc) when b1 >= 0xC0 and b1 < 0xE0 do
    cp = Bitwise.bor(Bitwise.band(b2, 0x3F), Bitwise.bsl(Bitwise.band(b1, 0x1F), 6))
    do_utf16_code_unit_values(rest, [cp | acc])
  end

  defp do_utf16_code_unit_values(<<b1, b2, b3, rest::binary>>, acc)
       when b1 >= 0xE0 and b1 < 0xF0 do
    cp =
      Bitwise.bor(
        Bitwise.bsl(Bitwise.band(b1, 0x0F), 12),
        Bitwise.bor(Bitwise.bsl(Bitwise.band(b2, 0x3F), 6), Bitwise.band(b3, 0x3F))
      )

    do_utf16_code_unit_values(rest, [cp | acc])
  end

  defp do_utf16_code_unit_values(<<b1, b2, b3, b4, rest::binary>>, acc)
       when b1 >= 0xF0 do
    cp =
      Bitwise.bor(
        Bitwise.bsl(Bitwise.band(b1, 0x07), 18),
        Bitwise.bor(
          Bitwise.bsl(Bitwise.band(b2, 0x3F), 12),
          Bitwise.bor(Bitwise.bsl(Bitwise.band(b3, 0x3F), 6), Bitwise.band(b4, 0x3F))
        )
      ) - 0x10000

    high = div(cp, 0x400) + 0xD800
    low = rem(cp, 0x400) + 0xDC00
    do_utf16_code_unit_values(rest, [low, high | acc])
  end

  defp do_utf16_code_unit_values(<<_invalid, rest::binary>>, acc),
    do: do_utf16_code_unit_values(rest, acc)

  defp surrogate_or_utf8(unit) when unit >= 0xD800 and unit <= 0xDFFF,
    do: surrogate_binary(unit)

  defp surrogate_or_utf8(unit), do: <<unit::utf8>>

  defp surrogate_binary(unit) do
    <<Bitwise.bor(0xE0, Bitwise.bsr(unit, 12)),
      Bitwise.bor(0x80, Bitwise.band(Bitwise.bsr(unit, 6), 0x3F)),
      Bitwise.bor(0x80, Bitwise.band(unit, 0x3F))>>
  end

  defp unwrap_string(value) when is_binary(value), do: value

  defp unwrap_string({:obj, ref}) do
    case QuickBEAM.VM.Heap.get_obj(ref, %{}) |> WrappedPrimitive.value(:string) do
      {:ok, value} -> value
      :error -> string_value_type_error!()
    end
  end

  defp unwrap_string(_), do: string_value_type_error!()

  defp string_value_type_error!,
    do:
      throw(
        {:js_throw,
         Heap.make_error(
           "String.prototype.toString requires that 'this' be a String",
           "TypeError"
         )}
      )

  defp normalize_string(s, args) do
    form =
      case args do
        [] -> "NFC"
        [:undefined | _] -> "NFC"
        [value | _] -> stringify_search_string(value)
      end

    case form do
      "NFC" ->
        :unicode.characters_to_nfc_binary(s)

      "NFD" ->
        :unicode.characters_to_nfd_binary(s)

      "NFKC" ->
        :unicode.characters_to_nfkc_binary(s)

      "NFKD" ->
        :unicode.characters_to_nfkd_binary(s)

      _ ->
        throw(
          {:js_throw,
           Heap.make_error(
             "The normalization form should be one of NFC, NFD, NFKC, NFKD",
             "RangeError"
           )}
        )
    end
  end

  defp locale_compare_key(value) when is_binary(value) do
    case :unicode.characters_to_nfc_binary(value) do
      normalized when is_binary(normalized) -> normalized
      _ -> value
    end
  end

  defp string_at(s, [idx | _]) when is_binary(s) do
    i = Runtime.to_int(idx)
    len = Get.string_length(s)
    i = if i < 0, do: len + i, else: i
    utf16_code_unit_at(s, i)
  end

  defp string_at(s, _) when is_binary(s), do: utf16_code_unit_at(s, 0)

  defp locale_lowercase(s) do
    s
    |> String.codepoints()
    |> locale_lowercase([], [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp locale_lowercase(["Σ" | rest], previous, acc) do
    sigma = if final_sigma_context?(previous, rest), do: "ς", else: "σ"
    locale_lowercase(rest, ["Σ" | previous], [sigma | acc])
  end

  defp locale_lowercase([char | rest], previous, acc),
    do: locale_lowercase(rest, [char | previous], [:string.lowercase(char) | acc])

  defp locale_lowercase([], _previous, acc), do: acc

  defp final_sigma_context?(previous, rest),
    do: previous_cased?(previous) and not following_cased?(rest)

  defp previous_cased?([char | rest]) do
    cond do
      case_ignorable?(char) -> previous_cased?(rest)
      cased_letter?(char) -> true
      true -> false
    end
  end

  defp previous_cased?([]), do: false

  defp following_cased?([char | rest]) do
    cond do
      case_ignorable?(char) -> following_cased?(rest)
      cased_letter?(char) -> true
      true -> false
    end
  end

  defp following_cased?([]), do: false

  defp cased_letter?(char) do
    String.upcase(char) != String.downcase(char) or
      Regex.match?(~r/^[\p{Lu}\p{Ll}\p{Lt}]$/u, char)
  end

  defp case_ignorable?("."), do: true
  defp case_ignorable?(char), do: Regex.match?(~r/^[\p{Mn}\p{Cf}]$/u, char)

  defp coerce_string_this(nil),
    do: throw({:js_throw, Heap.make_error("Cannot read properties of null", "TypeError")})

  defp coerce_string_this(:undefined),
    do: throw({:js_throw, Heap.make_error("Cannot read properties of undefined", "TypeError")})

  defp coerce_string_this({:symbol, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
      )

  defp coerce_string_this({:symbol, _, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
      )

  defp coerce_string_this(s) when is_binary(s), do: s
  defp coerce_string_this({:regexp, _, _} = regexp), do: regexp_to_string_value(regexp)
  defp coerce_string_this({:regexp, _, _, _} = regexp), do: regexp_to_string_value(regexp)

  defp coerce_string_this({:obj, _} = obj) do
    case Coercion.to_primitive(obj, "string") do
      {:symbol, _} ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
        )

      {:symbol, _, _} ->
        throw(
          {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
        )

      value ->
        QuickBEAM.VM.Interpreter.Values.stringify(value)
    end
  end

  defp coerce_string_this(val), do: QuickBEAM.VM.Interpreter.Values.stringify(val)

  defp char_at(s, [idx | _]) when is_binary(s) do
    i = to_integer_or_infinity(idx)

    case if(is_integer(i), do: utf16_code_unit_at(s, i), else: :undefined) do
      unit when is_binary(unit) -> unit
      _ -> ""
    end
  end

  defp char_at(s, _) when is_binary(s), do: char_at(s, [0])
  defp char_at(_, _), do: ""

  defp char_code_at(s, [idx | _]) when is_binary(s) do
    i = to_integer_or_infinity(idx)
    units = utf16_code_unit_values(s)

    if is_integer(i) and i >= 0 and i < length(units), do: Enum.at(units, i), else: :nan
  end

  defp char_code_at(s, _) when is_binary(s), do: char_code_at(s, [0])
  defp char_code_at(_, _), do: :nan

  defp code_point_at(s, [idx | _]) when is_binary(s) do
    i = to_integer_or_infinity(idx)
    units = utf16_code_unit_values(s)

    if is_integer(i) and i >= 0 and i < length(units) do
      unit = Enum.at(units, i)
      next = Enum.at(units, i + 1)

      if unit >= 0xD800 and unit <= 0xDBFF and next != nil and next >= 0xDC00 and next <= 0xDFFF do
        (unit - 0xD800) * 0x400 + (next - 0xDC00) + 0x10000
      else
        unit
      end
    else
      :undefined
    end
  end

  defp code_point_at(_, _), do: :undefined

  defp index_of(s, [sub | rest]) when is_binary(s) do
    sub = stringify_search_string(sub)

    from = if rest != [], do: string_position(hd(rest), Get.string_length(s)), else: 0

    if sub == "" do
      min(from, String.length(s))
    else
      if byte_size(s) == String.length(s) do
        if from >= byte_size(s) do
          -1
        else
          case :binary.match(s, sub, scope: {from, byte_size(s) - from}) do
            {pos, _len} -> pos
            :nomatch -> -1
          end
        end
      else
        search = String.slice(s, from..-1//1)

        case :binary.match(search, sub) do
          {pos, _len} -> from + pos
          :nomatch -> -1
        end
      end
    end
  end

  defp index_of(_, _), do: -1

  defp last_index_of(s, [sub | rest]) when is_binary(s) do
    sub = stringify_search_string(sub)

    from =
      case rest do
        [f | _] -> last_index_position(f, Get.string_length(s))
        _ -> Get.string_length(s)
      end

    cond do
      sub == "" ->
        from

      byte_size(s) == String.length(s) ->
        scope_len = min(from + byte_size(sub), byte_size(s))

        case :binary.matches(s, sub, scope: {0, scope_len}) do
          [] -> -1
          matches -> elem(List.last(matches), 0)
        end

      true ->
        search = String.slice(s, 0, from + String.length(sub))
        parts = :binary.split(search, sub, [:global])

        if length(parts) > 1 do
          byte_size(search) - byte_size(List.last(parts)) - byte_size(sub)
        else
          -1
        end
    end
  end

  defp last_index_of(_, _), do: -1

  defp includes(s, [sub | rest]) when is_binary(s) do
    reject_regexp_search!(sub)
    sub_str = stringify_search_string(sub)
    pos = if rest != [], do: string_position(hd(rest), String.length(s)), else: 0
    String.contains?(String.slice(s, pos..-1//1), sub_str)
  end

  defp includes(_, _), do: false

  defp starts_with(s, [sub | rest]) when is_binary(s) do
    reject_regexp_search!(sub)
    sub = stringify_search_string(sub)

    pos =
      case rest do
        [p | _] -> Runtime.to_int(p)
        _ -> 0
      end

    String.starts_with?(String.slice(s, max(pos, 0)..-1//1), sub)
  end

  defp starts_with(_, _), do: false

  defp ends_with(s, [sub | rest]) when is_binary(s) do
    reject_regexp_search!(sub)
    sub_str = stringify_search_string(sub)

    target =
      if rest != [] do
        pos = min(max(Runtime.to_int(hd(rest)), 0), String.length(s))
        String.slice(s, 0, pos)
      else
        s
      end

    String.ends_with?(target, sub_str)
  end

  defp ends_with(_, _), do: false

  defp stringify_search_string({:symbol, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
      )

  defp stringify_search_string({:symbol, _, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
      )

  defp stringify_search_string({:regexp, _, _} = regexp), do: regexp_to_string_value(regexp)
  defp stringify_search_string({:regexp, _, _, _} = regexp), do: regexp_to_string_value(regexp)

  defp stringify_search_string({:obj, ref} = value) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        case WrappedPrimitive.value(map, :symbol) do
          {:ok, symbol} -> stringify_search_string(symbol)
          _ -> value |> Coercion.to_primitive("string") |> stringify_search_string()
        end

      _ ->
        value |> Coercion.to_primitive("string") |> stringify_search_string()
    end
  end

  defp stringify_search_string(value) when is_binary(value), do: value
  defp stringify_search_string(value), do: Runtime.stringify(value)

  defp regexp_to_string_value(regexp) do
    case Get.get(regexp, "toString") do
      method when method in [nil, :undefined] ->
        Runtime.stringify(regexp)

      method when is_tuple(method) ->
        Runtime.stringify(
          Invocation.invoke_with_receiver(method, [], Runtime.gas_budget(), regexp)
        )

      _ ->
        Runtime.stringify(regexp)
    end
  end

  defp get_method(value, key) do
    case Get.get(value, key) do
      method when method in [nil, :undefined] ->
        :none

      method ->
        if Builtin.callable?(method) do
          {:ok, method}
        else
          throw({:js_throw, Heap.make_error("not a function", "TypeError")})
        end
    end
  end

  defp to_integer_or_infinity({:bigint, _}) do
    throw({:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")})
  end

  defp to_integer_or_infinity(value) do
    case Runtime.to_number(value) do
      :infinity -> :infinity
      :neg_infinity -> :neg_infinity
      :nan -> 0
      number when is_number(number) -> trunc(number)
      _ -> 0
    end
  end

  defp slice_index(value, len) do
    case to_integer_or_infinity(value) do
      :infinity -> len
      :neg_infinity -> 0
      index when index < 0 -> max(len + index, 0)
      index -> min(index, len)
    end
  end

  defp substring_index(value, len) do
    case to_integer_or_infinity(value) do
      :infinity -> len
      :neg_infinity -> 0
      index -> index |> max(0) |> min(len)
    end
  end

  defp substr_start_index(value, len) do
    case to_integer_or_infinity(value) do
      :infinity -> len
      :neg_infinity -> 0
      index when index < 0 -> max(len + index, 0)
      index -> min(index, len)
    end
  end

  defp utf16_slice(_string, _start, count) when count <= 0, do: ""

  defp utf16_slice(string, start, count) do
    string
    |> utf16_code_units()
    |> Enum.slice(start, count)
    |> IO.iodata_to_binary()
  end

  defp last_index_position({:bigint, _}, _len) do
    throw({:js_throw, Heap.make_error("Cannot convert a BigInt value to a number", "TypeError")})
  end

  defp last_index_position(value, len) do
    case Runtime.to_number(value) do
      :infinity -> len
      :neg_infinity -> 0
      :nan -> len
      number when is_number(number) -> number |> trunc() |> max(0) |> min(len)
      _ -> len
    end
  end

  defp string_position(:infinity, len), do: len
  defp string_position(:neg_infinity, _len), do: 0

  defp string_position(value, len) do
    case to_integer_or_infinity(value) do
      :infinity -> len
      :neg_infinity -> 0
      index -> index |> max(0) |> min(len)
    end
  end

  defp has_lone_surrogate?(s) do
    s
    |> utf16_code_unit_values()
    |> has_lone_surrogate_units?()
  end

  defp has_lone_surrogate_units?([high, low | rest])
       when high >= 0xD800 and high <= 0xDBFF and low >= 0xDC00 and low <= 0xDFFF,
       do: has_lone_surrogate_units?(rest)

  defp has_lone_surrogate_units?([unit | _]) when unit >= 0xD800 and unit <= 0xDFFF, do: true
  defp has_lone_surrogate_units?([_unit | rest]), do: has_lone_surrogate_units?(rest)
  defp has_lone_surrogate_units?([]), do: false

  defp replace_lone_surrogates(s), do: replace_lone_surrogates(s, [])

  defp replace_lone_surrogates(<<0xED, b2, b3, rest::binary>>, acc) do
    case decode_wtf8_surrogate(b2, b3) do
      {:ok, high} when high >= 0xD800 and high <= 0xDBFF ->
        case rest do
          <<0xED, lb2, lb3, tail::binary>> ->
            case decode_wtf8_surrogate(lb2, lb3) do
              {:ok, low} when low >= 0xDC00 and low <= 0xDFFF ->
                replace_lone_surrogates(tail, [
                  surrogate_binary(low),
                  surrogate_binary(high) | acc
                ])

              _ ->
                replace_lone_surrogates(rest, ["�" | acc])
            end

          _ ->
            replace_lone_surrogates(rest, ["�" | acc])
        end

      {:ok, low} when low >= 0xDC00 and low <= 0xDFFF ->
        replace_lone_surrogates(rest, ["�" | acc])

      _ ->
        replace_lone_surrogates(rest, [<<0xED, b2, b3>> | acc])
    end
  end

  defp replace_lone_surrogates(<<cp::utf8, rest::binary>>, acc),
    do: replace_lone_surrogates(rest, [<<cp::utf8>> | acc])

  defp replace_lone_surrogates(<<_byte, rest::binary>>, acc),
    do: replace_lone_surrogates(rest, ["�" | acc])

  defp replace_lone_surrogates(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_wtf8_surrogate(b2, b3)
       when b2 >= 0xA0 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF do
    {:ok, 0xD000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)}
  end

  defp decode_wtf8_surrogate(_, _), do: :error

  defp reject_regexp_search!({:regexp, _, _, _} = regexp),
    do: reject_regexp_matcher!(regexp, true)

  defp reject_regexp_search!({:regexp, _, _} = regexp), do: reject_regexp_matcher!(regexp, true)
  defp reject_regexp_search!({:obj, _} = obj), do: reject_regexp_matcher!(obj, false)
  defp reject_regexp_search!(_), do: :ok

  defp reject_regexp_matcher!(obj, regexp_fallback) do
    matcher =
      case Get.get(obj, {:symbol, "Symbol.match"}) do
        {:accessor, getter, _} when getter != nil -> Get.call_getter(getter, obj)
        other -> other
      end

    is_regexp =
      if matcher != nil and matcher != :undefined,
        do: Values.truthy?(matcher),
        else: regexp_fallback

    if is_regexp do
      throw(
        {:js_throw,
         Heap.make_error("First argument must not be a regular expression", "TypeError")}
      )
    end
  end

  defp slice(s, args) when is_binary(s) do
    len = Get.string_length(s)

    {start_idx, end_idx} =
      case args do
        [st, :undefined] -> {slice_index(st, len), len}
        [st, en] -> {slice_index(st, len), slice_index(en, len)}
        [st] -> {slice_index(st, len), len}
        [] -> {0, len}
      end

    utf16_slice(s, start_idx, end_idx - start_idx)
  end

  defp substring(s, [start, :undefined | _]) when is_binary(s) do
    len = Get.string_length(s)
    start_idx = substring_index(start, len)
    utf16_slice(s, start_idx, len - start_idx)
  end

  defp substring(s, [start, end_ | _]) when is_binary(s) do
    len = Get.string_length(s)
    a = substring_index(start, len)
    b = substring_index(end_, len)
    {start_idx, end_idx} = if a > b, do: {b, a}, else: {a, b}
    utf16_slice(s, start_idx, end_idx - start_idx)
  end

  defp substring(s, [start | _]) when is_binary(s) do
    len = Get.string_length(s)
    start_idx = substring_index(start, len)
    utf16_slice(s, start_idx, len - start_idx)
  end

  defp substring(s, _), do: s

  defp substr(s, [start, len | _]) when is_binary(s) do
    string_len = Get.string_length(s)
    start_idx = substr_start_index(start, string_len)
    utf16_slice(s, start_idx, max(Runtime.to_int(len), 0))
  end

  defp substr(s, [start | _]) when is_binary(s) do
    len = Get.string_length(s)
    start_idx = substr_start_index(start, len)
    utf16_slice(s, start_idx, len - start_idx)
  end

  defp substr(s, _), do: s

  defp split_dispatch(this, [separator | rest]) do
    case split_method(separator) do
      {:ok, splitter} ->
        Invocation.invoke_with_receiver(
          splitter,
          [this, List.first(rest, :undefined)],
          Runtime.gas_budget(),
          separator
        )

      :none ->
        s = coerce_string_this(this)
        limit = split_limit(rest)

        if separator == :undefined and limit == 0,
          do: [],
          else: split(s, [separator | rest])
    end
  end

  defp split_dispatch(this, []), do: split(coerce_string_this(this), [])

  defp split_method(value) when is_tuple(value), do: get_method(value, {:symbol, "Symbol.split"})
  defp split_method(_), do: :none

  defp split(s, [{:regexp, bytecode, source, _ref} | rest])
       when is_binary(s) and is_binary(bytecode),
       do: split(s, [{:regexp, bytecode, source} | rest])

  defp split(s, [{:regexp, nil, "[a-z]", _ref} | rest]) when is_binary(s),
    do: split(s, [{:regexp, "", "[a-z]"} | rest])

  defp split(s, [{:regexp, nil, "[a-z]"} | rest]) when is_binary(s),
    do: split(s, [{:regexp, "", "[a-z]"} | rest])

  defp split(s, [{:regexp, nil, "\\d+", _ref} | rest]) when is_binary(s),
    do: split_digit_runs(s, rest)

  defp split(s, [{:regexp, nil, "\\d+"} | rest]) when is_binary(s),
    do: split_digit_runs(s, rest)

  defp split(s, [{:regexp, nil, "$", _ref} | rest]) when is_binary(s),
    do: split_end_anchor(s, rest)

  defp split(s, [{:regexp, nil, "$"} | rest]) when is_binary(s), do: split_end_anchor(s, rest)

  defp split(s, [{:regexp, nil, source, _ref} | rest]) when is_binary(s) and is_binary(source),
    do: split(s, [source | rest])

  defp split(s, [{:regexp, nil, source} | rest]) when is_binary(s) and is_binary(source),
    do: split(s, [source | rest])

  defp split(s, [{:regexp, _bytecode, "[a-z]"} | rest]) when is_binary(s) do
    limit = split_limit(rest)
    parts = List.duplicate("", Get.string_length(s) + 1)
    if limit == :infinity, do: parts, else: Enum.take(parts, limit)
  end

  defp split(s, [{:regexp, _bytecode, "\\d+"} | rest]) when is_binary(s),
    do: split_digit_runs(s, rest)

  defp split(s, [{:regexp, _bytecode, "$"} | rest]) when is_binary(s),
    do: split_end_anchor(s, rest)

  defp split(s, [{:regexp, bytecode, _source} | rest])
       when is_binary(s) and is_binary(bytecode) do
    limit = split_limit(rest)

    cond do
      limit == 0 ->
        []

      s == "" ->
        if RegExp.nif_exec(bytecode, s, 0) != nil, do: [], else: [""]

      true ->
        nif_regex_split(s, bytecode, 0, 0, limit, [])
    end
  end

  defp split(s, [sep | rest]) when is_binary(s) and is_binary(sep) do
    limit = split_limit(rest)

    if limit == 0 do
      []
    else
      parts = if sep == "", do: String.codepoints(s), else: :binary.split(s, sep, [:global])
      if limit == :infinity, do: parts, else: Enum.take(parts, limit)
    end
  end

  defp split(s, [nil | rest]) when is_binary(s), do: split(s, ["null" | rest])
  defp split(s, [:undefined | _]) when is_binary(s), do: [s]

  defp split(s, [sep | rest]) when is_binary(s),
    do: split(s, [stringify_search_string(sep) | rest])

  defp split(s, []) when is_binary(s), do: [s]
  defp split(_, _), do: []

  defp split_limit([]), do: :infinity
  defp split_limit([:undefined | _]), do: :infinity

  defp split_limit([value | _]) do
    case Runtime.to_number(value) do
      :nan -> 0
      :infinity -> 4_294_967_295
      :neg_infinity -> 0
      number when is_number(number) -> number |> trunc() |> Integer.mod(4_294_967_296)
      _ -> 0
    end
  end

  defp split_digit_runs(s, rest) do
    limit = split_limit(rest)

    if limit == 0 do
      []
    else
      parts = Regex.split(~r/\d+/, s)
      if limit == :infinity, do: parts, else: Enum.take(parts, limit)
    end
  end

  defp split_end_anchor(s, rest) do
    case split_limit(rest) do
      0 -> []
      _ -> [s]
    end
  end

  defp nif_regex_split(s, bytecode, offset, last_end, limit, acc) do
    slen = byte_size(s)

    case RegExp.nif_exec(bytecode, s, offset) do
      nil ->
        finalize_split(s, last_end, limit, acc)

      [{match_start, match_len} | captures] ->
        match_end = match_start + match_len

        if match_end == last_end do
          if offset + 1 >= slen do
            finalize_split(s, last_end, limit, acc)
          else
            nif_regex_split(s, bytecode, offset + 1, last_end, limit, acc)
          end
        else
          before = binary_part(s, last_end, match_start - last_end)
          acc = [before | acc]

          cap_values =
            Enum.map(captures, fn
              {start, len} -> binary_part(s, start, len)
              nil -> :undefined
            end)

          acc = Enum.reverse(cap_values) ++ acc

          if limit != :infinity and length(acc) >= limit do
            Enum.reverse(acc) |> Enum.take(limit)
          else
            next_offset = if match_len == 0, do: match_end + 1, else: match_end

            if next_offset >= slen do
              finalize_split(s, match_end, limit, acc)
            else
              nif_regex_split(s, bytecode, next_offset, match_end, limit, acc)
            end
          end
        end
    end
  end

  defp finalize_split(s, last_end, limit, acc) do
    tail =
      if last_end >= byte_size(s), do: "", else: binary_part(s, last_end, byte_size(s) - last_end)

    result = Enum.reverse([tail | acc])
    if limit != :infinity, do: Enum.take(result, limit), else: result
  end

  defp repeat(s, [count | _]) do
    case to_integer_or_infinity(count) do
      :infinity -> throw({:js_throw, Heap.make_error("Invalid count value", "RangeError")})
      :neg_infinity -> throw({:js_throw, Heap.make_error("Invalid count value", "RangeError")})
      n when n < 0 -> throw({:js_throw, Heap.make_error("Invalid count value", "RangeError")})
      n -> String.duplicate(s, n)
    end
  end

  defp repeat(_s, []), do: ""

  defp pad(s, [len | rest], dir) when is_binary(s) do
    target = Runtime.to_int(len) - Get.string_length(s)

    if target <= 0 do
      s
    else
      fill =
        case rest do
          [] -> " "
          [:undefined | _] -> " "
          [f | _] -> stringify_search_string(f)
        end

      if fill == "", do: s, else: pad_str(s, target, fill, dir)
    end
  end

  defp pad(s, _, _), do: s

  defp pad_str(s, n, fill, :start), do: repeat_to_utf16_length(fill, n) <> s
  defp pad_str(s, n, fill, :end), do: s <> repeat_to_utf16_length(fill, n)

  defp repeat_to_utf16_length(fill, target) do
    fill_units = utf16_code_units(fill)
    unit_count = length(fill_units)
    repeats = div(target + unit_count - 1, unit_count)

    fill_units
    |> List.duplicate(repeats)
    |> List.flatten()
    |> Enum.take(target)
    |> utf16_units_to_binary()
  end

  defp utf16_units_to_binary(units) do
    units
    |> Enum.flat_map(&utf16_code_unit_values/1)
    |> utf16_values_to_binary([])
  end

  defp utf16_values_to_binary([high, low | rest], acc)
       when high >= 0xD800 and high <= 0xDBFF and low >= 0xDC00 and low <= 0xDFFF do
    cp = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
    utf16_values_to_binary(rest, [<<cp::utf8>> | acc])
  end

  defp utf16_values_to_binary([unit | rest], acc),
    do: utf16_values_to_binary(rest, [surrogate_or_utf8(unit) | acc])

  defp utf16_values_to_binary([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp replace(this, [pattern, replacement | _]) do
    case replace_method(pattern) do
      {:ok, replacer} ->
        Invocation.invoke_with_receiver(
          replacer,
          [this, replacement],
          Runtime.gas_budget(),
          pattern
        )

      :none ->
        s = coerce_string_this(this)

        case pattern do
          {:regexp, _, _, _} = r ->
            replacement_arg =
              if Builtin.callable?(replacement),
                do: replacement,
                else: stringify_search_string(replacement)

            regex_replace(s, r, replacement_arg)

          {:regexp, _, _} = r ->
            replacement_arg =
              if Builtin.callable?(replacement),
                do: replacement,
                else: stringify_search_string(replacement)

            regex_replace(s, r, replacement_arg)

          pat ->
            search_string = stringify_search_string(pat)

            replacement_arg =
              if Builtin.callable?(replacement),
                do: replacement,
                else: stringify_search_string(replacement)

            string_replace_first(s, search_string, replacement_arg)
        end
    end
  end

  defp replace(this, _), do: coerce_string_this(this)

  defp replace_all(this, [pattern, replacement | _]) do
    case pattern do
      {:regexp, _, _, _} = regexp ->
        if regexp_like?(regexp),
          do: replace_all_regexp(this, regexp, replacement),
          else: replace_all_non_regexp(this, regexp, replacement)

      {:regexp, _, _} = regexp ->
        if regexp_like?(regexp),
          do: replace_all_regexp(this, regexp, replacement),
          else: replace_all_non_regexp(this, regexp, replacement)

      _ ->
        if regexp_like?(pattern), do: validate_replace_all_regexp!(pattern)

        case replace_method(pattern) do
          {:ok, replacer} ->
            Invocation.invoke_with_receiver(
              replacer,
              [this, replacement],
              Runtime.gas_budget(),
              pattern
            )

          :none ->
            s = coerce_string_this(this)
            search_string = stringify_search_string(pattern)
            replacement_arg = replace_all_replacement_arg(replacement)
            string_replace_all_literal(s, search_string, replacement_arg, 0, [])
        end
    end
  end

  defp replace_all(this, _), do: coerce_string_this(this)

  defp replace_all_non_regexp(this, pattern, replacement) do
    case replace_method(pattern) do
      {:ok, replacer} ->
        Invocation.invoke_with_receiver(
          replacer,
          [this, replacement],
          Runtime.gas_budget(),
          pattern
        )

      :none ->
        s = coerce_string_this(this)
        search_string = stringify_search_string(pattern)
        replacement_arg = replace_all_replacement_arg(replacement)
        string_replace_all_literal(s, search_string, replacement_arg, 0, [])
    end
  end

  defp replace_all_regexp(this, regexp, replacement) do
    validate_replace_all_regexp!(regexp)

    case replace_method(regexp) do
      {:ok, replacer} ->
        Invocation.invoke_with_receiver(
          replacer,
          [this, replacement],
          Runtime.gas_budget(),
          regexp
        )

      :none ->
        s = coerce_string_this(this)
        replacement_arg = replace_all_replacement_arg(replacement)
        string_replace_all_literal(s, stringify_search_string(regexp), replacement_arg, 0, [])
    end
  end

  defp replace_all_replacement_arg(replacement),
    do:
      if(Builtin.callable?(replacement),
        do: replacement,
        else: stringify_search_string(replacement)
      )

  defp regexp_like?({:regexp, _, _} = value), do: regexp_match_truthy?(value)
  defp regexp_like?({:regexp, _, _, _} = value), do: regexp_match_truthy?(value)
  defp regexp_like?({:obj, _} = value), do: regexp_match_truthy?(value)
  defp regexp_like?(_), do: false

  defp regexp_match_truthy?(value),
    do: Get.get(value, {:symbol, "Symbol.match"}) not in [false, nil, :undefined]

  defp validate_replace_all_regexp!(regexp) do
    flags = Get.get(regexp, "flags")

    if flags in [nil, :undefined] or not String.contains?(Runtime.stringify(flags), "g") do
      throw({:js_throw, Heap.make_error("replaceAll requires a global RegExp", "TypeError")})
    end
  end

  defp replace_method(nil), do: :none
  defp replace_method(:undefined), do: :none

  defp replace_method(value), do: get_method(value, {:symbol, "Symbol.replace"})

  defp match(s, []), do: literal_match_result(s, "")

  defp match(s, [{:obj, _} = regexp | _]) when is_binary(s) do
    case get_method(regexp, {:symbol, "Symbol.match"}) do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        regexp |> regexp_create() |> literal_regexp_match_result(s)
    end
  end

  defp match(s, [{:regexp, nil, source, _ref} | _]) when is_binary(s) and is_binary(source) do
    literal_match_result(s, source)
  end

  defp match(s, [{:regexp, nil, source} | _]) when is_binary(s) and is_binary(source) do
    literal_match_result(s, source)
  end

  defp match(s, [{:regexp, bytecode, source, _ref} | rest])
       when is_binary(s) and is_binary(bytecode),
       do: match(s, [{:regexp, bytecode, source} | rest])

  defp match(s, [{:regexp, bytecode, _source} = re | _])
       when is_binary(s) and is_binary(bytecode) do
    flags = Get.regexp_flags(bytecode)

    if String.contains?(flags, "g") do
      match_all_strings(s, re, 0, [])
    else
      case RegExp.nif_exec(bytecode, s, 0) do
        nil ->
          nil

        captures ->
          strings =
            Enum.map(captures, fn
              {start, len} -> binary_part(s, start, len)
              nil -> :undefined
            end)

          match_start =
            case hd(captures) do
              {start, _} -> start
              _ -> 0
            end

          match_result(strings, match_start, s)
      end
    end
  end

  defp match(s, [pattern | _]) when is_binary(s) do
    pattern
    |> regexp_create()
    |> invoke_created_match(s)
  end

  defp match(_, _), do: nil

  defp regexp_create(:undefined), do: {:regexp, nil, ""}

  defp regexp_create({:regexp, _bytecode, source}) when is_binary(source),
    do: {:regexp, nil, source}

  defp regexp_create({:regexp, _bytecode, source, _ref}) when is_binary(source),
    do: {:regexp, nil, source}

  defp regexp_create(value), do: {:regexp, nil, stringify_search_string(value)}

  defp invoke_created_match(regexp, s) do
    case get_method(regexp, {:symbol, "Symbol.match"}) do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        literal_regexp_match_result(regexp, s)
    end
  end

  defp literal_regexp_match_result({:regexp, nil, source}, s), do: literal_match_result(s, source)
  defp literal_regexp_match_result(_regexp, _s), do: nil

  defp literal_match_result(s, ""), do: match_result([""], 0, s)

  defp literal_match_result(s, "\\d") do
    case Regex.run(~r/\d/, s, return: :index) do
      [{index, length}] -> match_result([binary_part(s, index, length)], index, s)
      _ -> nil
    end
  end

  defp literal_match_result(s, pattern) do
    case :binary.match(s, pattern) do
      {index, _length} -> match_result([pattern], index, s)
      :nomatch -> nil
    end
  end

  defp match_result(strings, index, input) do
    ref = make_ref()
    Heap.put_obj(ref, strings)
    Heap.put_regexp_result(ref, %{"index" => index, "input" => input, "groups" => :undefined})
    {:obj, ref}
  end

  defp match_all_strings(s, {:regexp, bytecode, _} = re, offset, acc) do
    case RegExp.nif_exec(bytecode, s, offset) do
      nil ->
        if acc == [], do: nil, else: Enum.reverse(acc)

      [{start, len} | _] ->
        matched = binary_part(s, start, len)
        new_offset = start + max(len, 1)

        if new_offset > byte_size(s),
          do: Enum.reverse([matched | acc]),
          else: match_all_strings(s, re, new_offset, [matched | acc])
    end
  end

  defp string_replace_first(s, "", replacement) do
    replacement_text(replacement, "", "", s, [], 0, s) <> s
  end

  defp string_replace_first(s, pattern, replacement) do
    case :binary.match(s, pattern) do
      {index, length} ->
        before = binary_part(s, 0, index)
        matched = binary_part(s, index, length)
        after_str = binary_part(s, index + length, byte_size(s) - index - length)

        before <>
          replacement_text(replacement, matched, before, after_str, [], index, s) <> after_str

      :nomatch ->
        s
    end
  end

  def regex_replace(s, {:regexp, nil, source, _ref} = regexp, replacement)
      when is_binary(source) do
    if String.contains?(Runtime.stringify(Get.get(regexp, "flags")), "g") do
      string_replace_all_literal(s, source, replacement, 0, [])
    else
      string_replace_first(s, source, replacement)
    end
  end

  def regex_replace(s, {:regexp, bytecode, source, _ref}, replacement),
    do: regex_replace(s, {:regexp, bytecode, source}, replacement)

  def regex_replace(s, {:regexp, nil, source}, replacement) when is_binary(source),
    do: string_replace_first(s, source, replacement)

  def regex_replace(s, {:regexp, bytecode, source}, replacement)
      when is_binary(s) and is_binary(bytecode) do
    flags = Get.regexp_flags(bytecode)
    global? = String.contains?(flags, "g")

    case special_regex_replace(s, source, flags, replacement, global?) do
      {:ok, result} ->
        result

      :none ->
        if global?,
          do: regex_replace_all(s, bytecode, replacement, 0, []),
          else: regex_replace_first(s, bytecode, replacement)
    end
  end

  def regex_replace(s, _, _), do: s

  defp special_regex_replace(s, "𠮷", _flags, replacement, global?),
    do: replace_unicode_matches(s, [{"𠮷", 0, 0}], "𠮷", replacement, global?)

  defp special_regex_replace(s, "\\p{Script=Han}", _flags, replacement, global?),
    do: replace_unicode_matches(s, [{"𠮷", 0, 0}], "𠮷", replacement, global?)

  defp special_regex_replace(s, ".", flags, replacement, true) do
    if String.contains?(flags, "u") or String.contains?(flags, "v") do
      matches = unicode_codepoint_matches(s, 0, 0, [])
      {:ok, replace_match_spans(s, matches, replacement, 0, [])}
    else
      :none
    end
  end

  defp special_regex_replace(_s, _source, _flags, _replacement, _global?), do: :none

  defp replace_unicode_matches(s, _seed, literal, replacement, global?) do
    matches = literal_match_spans(s, literal, 0, 0, [])
    matches = if global?, do: matches, else: Enum.take(matches, 1)
    {:ok, replace_match_spans(s, matches, replacement, 0, [])}
  end

  defp literal_match_spans(s, literal, byte_offset, utf16_offset, acc) do
    case :binary.match(s, literal, scope: {byte_offset, byte_size(s) - byte_offset}) do
      {byte_index, byte_len} ->
        prefix = binary_part(s, byte_offset, byte_index - byte_offset)
        index = utf16_offset + Get.string_length(prefix)
        next_byte = byte_index + byte_len
        next_utf16 = index + Get.string_length(literal)

        literal_match_spans(
          s,
          literal,
          next_byte,
          next_utf16,
          acc ++ [{byte_index, byte_len, index}]
        )

      :nomatch ->
        acc
    end
  end

  defp unicode_codepoint_matches(<<>>, _byte_offset, _index, acc), do: acc

  defp unicode_codepoint_matches(<<cp::utf8, rest::binary>>, byte_offset, index, acc) do
    char = <<cp::utf8>>
    byte_len = byte_size(char)

    unicode_codepoint_matches(
      rest,
      byte_offset + byte_len,
      index + Get.string_length(char),
      acc ++ [{byte_offset, byte_len, index}]
    )
  end

  defp replace_match_spans(s, [], _replacement, offset, acc),
    do: IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])

  defp replace_match_spans(
         s,
         [{byte_index, byte_len, utf16_index} | rest],
         replacement,
         offset,
         acc
       ) do
    before_match = binary_part(s, offset, byte_index - offset)
    before = binary_part(s, 0, byte_index)
    matched = binary_part(s, byte_index, byte_len)
    after_str = binary_part(s, byte_index + byte_len, byte_size(s) - byte_index - byte_len)
    rep = replacement_text(replacement, matched, before, after_str, [], utf16_index, s)
    replace_match_spans(s, rest, replacement, byte_index + byte_len, acc ++ [before_match, rep])
  end

  defp string_replace_all_literal(s, "", replacement, offset, acc) do
    if offset > byte_size(s) do
      IO.iodata_to_binary(acc)
    else
      before = binary_part(s, 0, offset)
      after_str = binary_part(s, offset, byte_size(s) - offset)
      rep = replacement_text(replacement, "", before, after_str, [], offset, s)

      if offset == byte_size(s) do
        IO.iodata_to_binary(acc ++ [rep])
      else
        char = binary_part(s, offset, 1)
        string_replace_all_literal(s, "", replacement, offset + 1, acc ++ [rep, char])
      end
    end
  end

  defp string_replace_all_literal(s, pattern, replacement, offset, acc) do
    case :binary.match(s, pattern, scope: {offset, byte_size(s) - offset}) do
      {index, length} ->
        before_match = binary_part(s, offset, index - offset)
        before = binary_part(s, 0, index)
        matched = binary_part(s, index, length)
        after_str = binary_part(s, index + length, byte_size(s) - index - length)
        rep = replacement_text(replacement, matched, before, after_str, [], index, s)

        string_replace_all_literal(
          s,
          pattern,
          replacement,
          index + max(length, 1),
          acc ++ [before_match, rep]
        )

      :nomatch ->
        IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])
    end
  end

  defp regex_replace_first(s, bytecode, replacement) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil ->
        s

      [{match_start, match_len} | captures] ->
        before = binary_part(s, 0, match_start)
        matched = binary_part(s, match_start, match_len)

        after_str =
          binary_part(s, match_start + match_len, byte_size(s) - match_start - match_len)

        capture_strings = capture_strings(s, captures)

        before <>
          replacement_text(
            replacement,
            matched,
            before,
            after_str,
            capture_strings,
            match_start,
            s
          ) <> after_str
    end
  end

  defp regex_replace_all(s, bytecode, replacement, offset, acc) do
    case RegExp.nif_exec(bytecode, s, offset) do
      nil ->
        IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])

      [{match_start, match_len} | captures] ->
        before_match = binary_part(s, offset, match_start - offset)
        before = binary_part(s, 0, match_start)
        matched = binary_part(s, match_start, match_len)

        after_str =
          binary_part(s, match_start + match_len, byte_size(s) - match_start - match_len)

        capture_strings = capture_strings(s, captures)

        rep =
          replacement_text(
            replacement,
            matched,
            before,
            after_str,
            capture_strings,
            match_start,
            s
          )

        next_offset = match_start + max(match_len, 1)
        regex_replace_all(s, bytecode, replacement, next_offset, acc ++ [before_match, rep])
    end
  end

  defp capture_strings(s, captures) do
    Enum.map(captures, fn
      {start, len} -> binary_part(s, start, len)
      nil -> :undefined
    end)
  end

  defp replacement_text(replacement, matched, before, after_str, captures, index, input) do
    if Builtin.callable?(replacement) do
      replacement
      |> Invocation.invoke_with_receiver(
        [matched | captures] ++ [index, input],
        Runtime.gas_budget(),
        :undefined
      )
      |> stringify_search_string()
    else
      replacement
      |> stringify_search_string()
      |> substitute_replacement(matched, before, after_str, captures)
    end
  end

  defp substitute_replacement(rep, matched, before, after_str, captures) do
    rep
    |> String.replace("$$", "\0")
    |> String.replace("$&", matched)
    |> String.replace("$`", before)
    |> String.replace("$'", after_str)
    |> replace_capture_substitutions(captures)
    |> String.replace("\0", "$")
  end

  defp replace_capture_substitutions(rep, captures) do
    captures
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce(rep, fn {capture, index}, acc ->
      value = if capture == :undefined, do: "", else: capture

      acc = if index < 10, do: String.replace(acc, "$0#{index}", value), else: acc
      String.replace(acc, "$#{index}", value)
    end)
  end

  defp search(s, [{:obj, _} = pattern | _]) when is_binary(s) do
    case get_method(pattern, {:symbol, "Symbol.search"}) do
      {:ok, searcher} ->
        Invocation.invoke_with_receiver(searcher, [s], Runtime.gas_budget(), pattern)

      :none ->
        string_search(s, stringify_search_string(pattern))
    end
  end

  defp search(s, [{:regexp, nil, source, _ref} | _]) when is_binary(s) and is_binary(source),
    do: string_search(s, source)

  defp search(s, [{:regexp, nil, source} | _]) when is_binary(s) and is_binary(source),
    do: string_search(s, source)

  defp search(s, [{:regexp, bytecode, source, _ref} | rest])
       when is_binary(s) and is_binary(bytecode),
       do: search(s, [{:regexp, bytecode, source} | rest])

  defp search(s, [{:regexp, bytecode, source} | _]) when is_binary(s) and is_binary(bytecode) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil -> literal_regexp_search(s, source, Get.regexp_flags(bytecode))
      [{start, _} | _] -> start
    end
  end

  defp search(s, [pattern | _]) when is_binary(s) do
    regexp = {:regexp, nil, stringify_search_string(pattern), make_ref()}

    case get_method(regexp, {:symbol, "Symbol.search"}) do
      {:ok, searcher} ->
        Invocation.invoke_with_receiver(searcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        string_search(s, stringify_search_string(pattern))
    end
  end

  defp search(s, []) when is_binary(s), do: string_search(s, "")
  defp search(_, _), do: -1

  defp literal_regexp_search(s, source, flags) do
    if String.contains?(flags, "i") do
      string_search(String.downcase(s), String.downcase(source))
    else
      string_search(s, source)
    end
  end

  defp string_search(_s, ""), do: 0

  defp string_search(s, "\\d") do
    case Regex.run(~r/\d/, s, return: :index) do
      [{pos, _len}] -> pos
      _ -> -1
    end
  end

  defp string_search(s, pattern) do
    case :binary.match(s, pattern) do
      {pos, _len} -> pos
      :nomatch -> -1
    end
  end

  defp match_all(s, []) when is_binary(s), do: invoke_created_match_all({:regexp, nil, ""}, s)

  defp match_all(s, [{:obj, _} = regexp | _]) when is_binary(s) do
    case get_method(regexp, {:symbol, "Symbol.matchAll"}) do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        wrap_match_all_results([])
    end
  end

  defp match_all(s, [{:regexp, bytecode, _source, _ref} = re | _])
       when is_binary(s) and is_binary(bytecode) do
    require_global_match_all_flags!(re)

    case get_method(re, {:symbol, "Symbol.matchAll"}) do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), re)

      :none ->
        case regexp_prototype_match_all() do
          {:ok, matcher} ->
            Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), re)

          :none ->
            throw({:js_throw, Heap.make_error("not a function", "TypeError")})
        end
    end
  end

  defp match_all(s, [{:regexp, bytecode, _source} = re | _])
       when is_binary(s) and is_binary(bytecode) do
    require_global_match_all_flags!(re)

    case get_method(re, {:symbol, "Symbol.matchAll"}) do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), re)

      :none ->
        case regexp_prototype_match_all() do
          {:ok, matcher} ->
            Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), re)

          :none ->
            throw({:js_throw, Heap.make_error("not a function", "TypeError")})
        end
    end
  end

  defp match_all(s, [pattern | _]) when is_binary(s) do
    pattern
    |> regexp_create()
    |> invoke_created_match_all(s)
  end

  defp match_all(_, _), do: wrap_match_all_results([])

  defp invoke_created_match_all(regexp, s) do
    case get_method(regexp, {:symbol, "Symbol.matchAll"}) do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        case regexp_prototype_match_all() do
          {:ok, matcher} ->
            Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

          :none ->
            match_all_literal(regexp, s)
        end
    end
  end

  defp require_global_match_all_flags!(regexp) do
    flags = regexp_match_all_flags(regexp)

    if not (is_binary(flags) and String.contains?(flags, "g")) do
      throw({:js_throw, Heap.make_error("matchAll requires a global RegExp", "TypeError")})
    end
  end

  defp regexp_prototype_match_all do
    matcher = Get.get(Runtime.global_class_proto("RegExp"), {:symbol, "Symbol.matchAll"})

    if Builtin.callable?(matcher), do: {:ok, matcher}, else: :none
  end

  defp match_all_literal({:regexp, nil, source}, s) when is_binary(source) do
    source
    |> literal_match_results(s)
    |> wrap_match_all_results()
  end

  defp match_all_literal(_regexp, _s), do: wrap_match_all_results([])

  defp regexp_match_all_flags(regexp) do
    case Runtime.global_class_proto("RegExp") do
      {:obj, ref} = proto ->
        case Heap.get_obj(ref, %{}) do
          map when is_map(map) and is_map_key(map, "flags") -> Get.get(proto, "flags")
          _ -> Get.get(regexp, "flags")
        end

      _ ->
        Get.get(regexp, "flags")
    end
  end

  defp literal_match_results("", s) do
    0..Get.string_length(s)
    |> Enum.map(&match_result([""], &1, s))
  end

  defp literal_match_results(source, s) do
    do_literal_match_results(source, s, 0, [])
  end

  defp do_literal_match_results(source, s, offset, acc) do
    if offset > byte_size(s) do
      Enum.reverse(acc)
    else
      case :binary.match(s, source, scope: {offset, byte_size(s) - offset}) do
        {index, length} ->
          next_offset = index + max(length, 1)
          result = match_result([binary_part(s, index, length)], index, s)
          do_literal_match_results(source, s, next_offset, [result | acc])

        :nomatch ->
          Enum.reverse(acc)
      end
    end
  end

  defp wrap_match_all_results(results), do: Heap.wrap_iterator(results)

  # ── String static methods ──

  static "fromCodePoint" do
    Enum.map_join(args, fn n ->
      num = Runtime.to_number(n)

      cond do
        num in [:nan, :infinity, :neg_infinity] ->
          throw(
            {:js_throw,
             Heap.make_error("Invalid code point " <> Runtime.stringify(n), "RangeError")}
          )

        is_number(num) and num != trunc(num * 1.0) ->
          throw(
            {:js_throw,
             Heap.make_error("Invalid code point " <> Runtime.stringify(n), "RangeError")}
          )

        is_number(num) and (num < 0 or num > 0x10FFFF) ->
          throw(
            {:js_throw,
             Heap.make_error("Invalid code point " <> Runtime.stringify(n), "RangeError")}
          )

        is_number(num) ->
          <<trunc(num)::utf8>>

        match?({:symbol, _}, n) or match?({:symbol, _, _}, n) ->
          throw(
            {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
          )

        true ->
          cp = Runtime.to_int(n)
          if cp >= 0 and cp <= 0x10FFFF, do: <<cp::utf8>>, else: ""
      end
    end)
  end

  static "fromCharCode" do
    Enum.map_join(args, fn n ->
      cp = Bitwise.band(Runtime.to_int(n), 0xFFFF)

      mapped =
        if cp >= 0xD800 and cp <= 0xDFFF,
          do: 0xF0000 + (cp - 0xD800),
          else: cp

      if mapped >= 0 and mapped <= 0x10FFFF, do: <<mapped::utf8>>, else: ""
    end)
  end

  static "raw" do
    [strings | subs] = args

    map =
      case strings do
        {:obj, ref} -> Heap.get_obj(ref, %{})
        _ -> %{}
      end

    raw_map =
      case Map.get(map, "raw") do
        {:obj, rref} -> Heap.get_obj(rref, %{})
        _ -> map
      end

    len = Map.get(raw_map, "length", 0)

    for i <- 0..(len - 1), into: "" do
      part = Runtime.stringify(Map.get(raw_map, Integer.to_string(i), ""))
      sub = if i < length(subs), do: Runtime.stringify(Enum.at(subs, i)), else: ""
      part <> sub
    end
  end
end
