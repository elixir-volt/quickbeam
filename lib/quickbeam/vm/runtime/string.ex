defmodule QuickBEAM.VM.Runtime.String do
  @moduledoc "String.prototype methods."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Value, only: [is_nullish: 1]

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.{Builtin, Heap, Invocation, JSThrow, Value}
  alias QuickBEAM.VM.Semantics.Values
  alias QuickBEAM.VM.Semantics.Coercion
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor, Put, WrappedPrimitive}
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.InstallerHelpers
  alias QuickBEAM.VM.Runtime.RegExp

  @prototype_methods ~w(charAt charCodeAt codePointAt indexOf lastIndexOf includes startsWith endsWith slice substring substr split trim trimStart trimEnd toUpperCase toLowerCase toLocaleUpperCase toLocaleLowerCase repeat padStart padEnd replace replaceAll match matchAll localeCompare search normalize concat toString valueOf at isWellFormed toWellFormed)

  builtin_definition("String",
    constructor: &QuickBEAM.VM.Runtime.Globals.Constructors.string/2,
    length: 1,
    phase: :fundamental,
    after_install: &__MODULE__.install_builtin/2
  )

  @doc "Installs String-specific prototype metadata."
  def install_builtin(ctor, opts \\ []) do
    object_proto = Keyword.get(opts, :object_proto, Heap.get_object_prototype())

    InstallerHelpers.with_prototype(ctor, fn proto_ref ->
      InstallerHelpers.install_methods(proto_ref, __MODULE__, @prototype_methods)

      proto_ref
      |> Heap.get_obj(%{})
      |> Map.put_new(WrappedPrimitive.slot(:string), "")
      |> put_object_prototype(object_proto)
      |> then(&Heap.put_obj(proto_ref, &1))

      InstallerHelpers.install_constructor_link(proto_ref, ctor)
      install_iterator(proto_ref)
    end)

    Heap.put_ctor_static(ctor, "length", 1)
    Heap.put_ctor_prop_desc(ctor, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_prop_desc(ctor, "prototype", PropertyDescriptor.prototype())
  end

  defp put_object_prototype(map, {:obj, _} = object_proto),
    do: Map.put(map, "__proto__", object_proto)

  defp put_object_prototype(map, _object_proto), do: map

  defp install_iterator(proto_ref) do
    sym_iterator = {:symbol, "Symbol.iterator"}

    iterator =
      case proto_property(sym_iterator) do
        {:builtin, _name, callback} -> {:builtin, "[Symbol.iterator]", callback}
        other -> other
      end

    Heap.put_obj_key(proto_ref, sym_iterator, iterator)
    Heap.put_prop_desc(proto_ref, sym_iterator, PropertyDescriptor.method())
    Heap.put_ctor_static(iterator, "length", 0)
    Heap.put_ctor_static(iterator, "name", "[Symbol.iterator]")
    Heap.put_ctor_prop_desc(iterator, "length", PropertyDescriptor.hidden_readonly())
    Heap.put_ctor_prop_desc(iterator, "name", PropertyDescriptor.hidden_readonly())
  end

  @trim_leading_pattern ~r/^[\t\n\x{000B}\f\r \x{00A0}\x{1680}\x{2000}\x{2001}\x{2002}\x{2003}\x{2004}\x{2005}\x{2006}\x{2007}\x{2008}\x{2009}\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+/u
  @trim_trailing_pattern ~r/[\t\n\x{000B}\f\r \x{00A0}\x{1680}\x{2000}\x{2001}\x{2002}\x{2003}\x{2004}\x{2005}\x{2006}\x{2007}\x{2008}\x{2009}\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+$/u
  @non_ecma_whitespace_run ~r/[^\t\n\x{000B}\f\r \x{00A0}\x{1680}\x{2000}\x{2001}\x{2002}\x{2003}\x{2004}\x{2005}\x{2006}\x{2007}\x{2008}\x{2009}\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+/u

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
    coerce_string_this(this) |> trim_js()
  end

  proto "trimStart" do
    coerce_string_this(this) |> trim_start_js()
  end

  proto "trimEnd" do
    coerce_string_this(this) |> trim_end_js()
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
    coerce_string_this(this) <> Enum.map_join(args, &Coercion.to_string_val/1)
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
    |> string_iterator_items()
    |> string_iterator_from()
  end

  # ── Implementations ──

  defp string_iterator_from(items) do
    iter = iterator_from(items)

    next_fn = string_iterator_next(iter)

    proto =
      Heap.wrap(%{
        "__proto__" => QuickBEAM.VM.Runtime.global_class_proto("Iterator"),
        "next" => next_fn,
        {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _, this -> this end},
        {:symbol, "Symbol.toStringTag"} => "String Iterator"
      })

    with {:obj, proto_ref} <- proto do
      Heap.put_prop_desc(proto_ref, "next", PropertyDescriptor.method())
      Heap.put_prop_desc(proto_ref, {:symbol, "Symbol.iterator"}, PropertyDescriptor.method())

      Heap.put_prop_desc(
        proto_ref,
        {:symbol, "Symbol.toStringTag"},
        PropertyDescriptor.hidden_readonly()
      )
    end

    with {:obj, ref} <- iter do
      Heap.put_obj_key(ref, "next", next_fn)
      Heap.put_obj_key(ref, "__proto__", proto)
    end

    iter
  end

  defp string_iterator_next({:obj, _} = iter) do
    raw_next =
      case iter do
        {:obj, ref} -> Heap.get_obj(ref, %{}) |> Map.get("next")
        _ -> :undefined
      end

    {:builtin, "next",
     fn _args, this ->
       if this == iter do
         Invocation.invoke_with_receiver(raw_next, [], iter)
       else
         throw(
           {:js_throw,
            Heap.make_error("String Iterator next called on incompatible receiver", "TypeError")}
         )
       end
     end}
  end

  defp string_iterator_next(_), do: :undefined

  @doc "Returns the JavaScript UTF-16 code-unit length of a string."
  def utf16_length(string) when is_binary(string) do
    if ascii_string?(string) do
      byte_size(string)
    else
      string |> utf16_code_unit_values() |> length()
    end
  end

  defp ascii_string?(<<>>), do: true
  defp ascii_string?(<<byte, rest::binary>>) when byte < 0x80, do: ascii_string?(rest)
  defp ascii_string?(_), do: false

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

  defp string_iterator_items(string), do: do_string_iterator_items(string, [])

  defp do_string_iterator_items(<<>>, acc), do: Enum.reverse(acc)

  defp do_string_iterator_items(<<cp, rest::binary>>, acc) when cp < 0x80,
    do: do_string_iterator_items(rest, [<<cp>> | acc])

  defp do_string_iterator_items(<<b1, b2, rest::binary>>, acc) when b1 >= 0xC0 and b1 < 0xE0,
    do: do_string_iterator_items(rest, [<<b1, b2>> | acc])

  defp do_string_iterator_items(<<h1, h2, h3, l1, l2, l3, rest::binary>>, acc)
       when h1 == 0xED and h2 >= 0xA0 and h2 <= 0xAF and l1 == 0xED and l2 >= 0xB0 and
              l2 <= 0xBF do
    do_string_iterator_items(rest, [<<h1, h2, h3, l1, l2, l3>> | acc])
  end

  defp do_string_iterator_items(<<b1, b2, b3, rest::binary>>, acc) when b1 >= 0xE0 and b1 < 0xF0,
    do: do_string_iterator_items(rest, [<<b1, b2, b3>> | acc])

  defp do_string_iterator_items(<<b1, b2, b3, b4, rest::binary>>, acc) when b1 >= 0xF0,
    do: do_string_iterator_items(rest, [<<b1, b2, b3, b4>> | acc])

  defp do_string_iterator_items(<<_invalid, rest::binary>>, acc),
    do: do_string_iterator_items(rest, acc)

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

  defp trim_js(s), do: s |> trim_start_js() |> trim_end_js()
  defp trim_start_js(s), do: Regex.replace(@trim_leading_pattern, s, "")
  defp trim_end_js(s), do: Regex.replace(@trim_trailing_pattern, s, "")

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

  defp coerce_string_this({:obj, ref}) do
    if Heap.get_array_prop(ref, "__arguments__") == true do
      "[object Arguments]"
    else
      coerce_object_to_string({:obj, ref})
    end
  end

  defp coerce_string_this(val), do: QuickBEAM.VM.Semantics.Values.stringify(val)

  defp coerce_object_to_string(obj) do
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
        QuickBEAM.VM.Semantics.Values.stringify(value)
    end
  end

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
      method when is_nullish(method) ->
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
    if Value.object_like?(value) do
      case Get.get(value, key) do
        method when is_nullish(method) ->
          :none

        method ->
          if Builtin.callable?(method) do
            {:ok, method}
          else
            throw({:js_throw, Heap.make_error("not a function", "TypeError")})
          end
      end
    else
      :none
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

  def utf16_slice(_string, _start, count) when count <= 0, do: ""

  def utf16_slice(string, start, count) do
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

  defp raw_to_length(value) do
    case Runtime.to_number(value) do
      :nan -> 0
      :undefined -> 0
      :neg_infinity -> 0
      :infinity -> 9_007_199_254_740_991
      number when is_number(number) -> number |> trunc() |> max(0) |> min(9_007_199_254_740_991)
      _ -> 0
    end
  end

  defp raw_to_string({:symbol, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
      )

  defp raw_to_string({:symbol, _, _}),
    do:
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a string", "TypeError")}
      )

  defp raw_to_string(value), do: stringify_search_string(value)

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

  defp split(s, [{:regexp, nil, source, _ref} = regexp | rest])
       when is_binary(s) and is_binary(source) do
    limit = split_limit(rest)

    cond do
      limit == 0 -> []
      custom_split_exec?(regexp) -> split_with_exec_loop(s, regexp, limit, 0, 0, [])
      source == "[a-z]" -> split(s, [{:regexp, "", source} | rest])
      source == "\\d+" -> split_digit_runs(s, rest)
      source == "$" -> split_end_anchor(s, rest)
      source == "" -> split(s, ["" | rest])
      true -> constructed_regex_split(s, source, limit)
    end
  end

  defp split(s, [{:regexp, bytecode, source, _ref} = regexp | rest])
       when is_binary(s) and is_binary(bytecode) do
    limit = split_limit(rest)

    cond do
      limit == 0 -> []
      s == "" -> split_empty_with_exec(s, regexp)
      source in ["\\w", "\\W", "\\d", "\\D", "\\s", "\\S"] -> split_class_escape(s, source, limit)
      true -> split_with_exec_loop(s, regexp, limit, 0, 0, [])
    end
  end

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

  defp split(s, [{:regexp, bytecode, source} = regexp | rest])
       when is_binary(s) and is_binary(bytecode) do
    limit = split_limit(rest)

    cond do
      limit == 0 ->
        []

      s == "" ->
        if RegExp.nif_exec(bytecode, s, 0) != nil, do: [], else: [""]

      custom_split_exec?(regexp) ->
        split_with_exec_loop(s, regexp, limit, 0, 0, [])

      source == "." and unicode_regexp_bytecode?(bytecode) ->
        split_unicode_codepoints(s, limit)

      source in ["\\w", "\\W", "\\d", "\\D", "\\s", "\\S"] ->
        split_class_escape(s, source, limit)

      true ->
        nif_regex_split(s, bytecode, 0, 0, limit, [])
    end
  end

  defp split(s, [{:obj, _} = splitter | rest]) when is_binary(s) do
    if regexp_like?(splitter) do
      limit = split_limit(rest)

      cond do
        limit == 0 -> []
        s == "" -> split_empty_with_exec(s, splitter)
        true -> split_with_exec_loop(s, splitter, limit, 0, 0, [])
      end
    else
      split(s, [stringify_search_string(splitter) | rest])
    end
  end

  defp split(s, [sep | rest]) when is_binary(s) and is_binary(sep) do
    limit = split_limit(rest)

    if limit == 0 do
      []
    else
      parts = if sep == "", do: utf16_code_units(s), else: :binary.split(s, sep, [:global])
      if limit == :infinity, do: parts, else: Enum.take(parts, limit)
    end
  end

  defp split(s, [nil | rest]) when is_binary(s), do: split(s, ["null" | rest])
  defp split(s, [:undefined | _]) when is_binary(s), do: [s]

  defp split(s, [sep | rest]) when is_binary(s),
    do: split(s, [stringify_search_string(sep) | rest])

  defp split(s, []) when is_binary(s), do: [s]
  defp split(_, _), do: []

  defp constructed_regex_split(s, source, limit) do
    case Regex.compile(source) do
      {:ok, regex} ->
        parts = Regex.split(regex, s, include_captures: true, trim: false)
        if limit == :infinity, do: parts, else: Enum.take(parts, limit)

      {:error, _} ->
        split(s, [source, limit])
    end
  end

  defp split_empty_with_exec(s, splitter) do
    split_put_last_index!(splitter, 0)

    case split_exec_result(splitter, s) do
      nil -> [""]
      _ -> []
    end
  end

  defp split_with_exec_loop(s, splitter, limit, q, p, acc),
    do: split_with_exec_loop(s, splitter, limit, q, p, acc, split_unicode_matching?(splitter))

  defp split_with_exec_loop(s, splitter, limit, q, p, acc, unicode?) do
    size = Get.string_length(s)

    cond do
      limited_split_done?(acc, limit) ->
        acc

      q >= size ->
        append_split_part(acc, utf16_slice(s, p, size - p), limit)

      true ->
        split_put_last_index!(splitter, q)

        case split_exec_result(splitter, s) do
          nil ->
            split_with_exec_loop(
              s,
              splitter,
              limit,
              split_advance_string_index(s, q, unicode?),
              p,
              acc,
              unicode?
            )

          {:obj, _} = result ->
            if split_default_exec?(splitter) and raw_to_length(Get.get(result, "index")) != q do
              split_with_exec_loop(
                s,
                splitter,
                limit,
                split_advance_string_index(s, q, unicode?),
                p,
                acc,
                unicode?
              )
            else
              e = min(raw_to_length(Get.get(splitter, "lastIndex")), size)

              if e == p do
                split_with_exec_loop(
                  s,
                  splitter,
                  limit,
                  split_advance_string_index(s, q, unicode?),
                  p,
                  acc,
                  unicode?
                )
              else
                part = utf16_slice(s, p, max(q - p, 0))
                acc = append_split_part(acc, part, limit)

                if limited_split_done?(acc, limit) do
                  acc
                else
                  captures = split_result_captures(result)
                  acc = append_split_parts(acc, captures, limit)
                  split_with_exec_loop(s, splitter, limit, e, e, acc, unicode?)
                end
              end
            end
        end
    end
  end

  defp split_unicode_codepoints(s, limit) do
    parts = List.duplicate("", length(String.codepoints(s)) + 1)
    if limit == :infinity, do: parts, else: Enum.take(parts, limit)
  end

  defp split_class_escape(s, source, limit) do
    parts = split_class_escape_units(utf16_code_units(s), source, [], [])
    if limit == :infinity, do: parts, else: Enum.take(parts, limit)
  end

  defp split_class_escape_units([], _source, current, acc),
    do: Enum.reverse([current |> Enum.reverse() |> IO.iodata_to_binary() | acc])

  defp split_class_escape_units([unit | rest], source, current, acc) do
    if class_escape_match?(unit, source) do
      part = current |> Enum.reverse() |> IO.iodata_to_binary()
      split_class_escape_units(rest, source, [], [part | acc])
    else
      split_class_escape_units(rest, source, [unit | current], acc)
    end
  end

  defp class_escape_match?(unit, "\\d"), do: unit >= "0" and unit <= "9"
  defp class_escape_match?(unit, "\\D"), do: not class_escape_match?(unit, "\\d")
  defp class_escape_match?(unit, "\\w"), do: word_unit?(unit)
  defp class_escape_match?(unit, "\\W"), do: not word_unit?(unit)
  defp class_escape_match?(unit, "\\s"), do: unit in [" ", "\t", "\n", "\r", "\f", "\v"]
  defp class_escape_match?(unit, "\\S"), do: not class_escape_match?(unit, "\\s")

  defp word_unit?(unit),
    do:
      (unit >= "0" and unit <= "9") or (unit >= "A" and unit <= "Z") or
        (unit >= "a" and unit <= "z") or unit == "_"

  defp unicode_regexp_bytecode?(bytecode) do
    flags = QuickBEAM.VM.ObjectModel.Get.regexp_flags(bytecode)
    String.contains?(flags, "u") or String.contains?(flags, "v")
  end

  defp split_unicode_matching?(splitter) do
    flags = Runtime.stringify(Get.get(splitter, "flags"))
    String.contains?(flags, "u") or String.contains?(flags, "v")
  end

  defp split_advance_string_index(s, index, true) do
    units = utf16_code_unit_values(s)
    first = Enum.at(units, index, :undefined)
    second = Enum.at(units, index + 1, :undefined)

    if is_integer(first) and first >= 0xD800 and first <= 0xDBFF and is_integer(second) and
         second >= 0xDC00 and second <= 0xDFFF,
       do: index + 2,
       else: index + 1
  end

  defp split_advance_string_index(_s, index, false), do: index + 1

  defp custom_split_exec?(splitter) do
    exec = Get.get(splitter, "exec")
    Builtin.callable?(exec) and not match?({:builtin, "exec", _}, exec)
  end

  defp split_default_exec?(splitter), do: not custom_split_exec?(splitter)

  defp split_put_last_index!({:regexp, _, _, ref} = regexp, value) do
    case Heap.get_prop_desc(ref, "lastIndex") do
      %{writable: false} -> JSThrow.type_error!("Cannot assign to read only property")
      _ -> Put.put(regexp, "lastIndex", value)
    end
  end

  defp split_put_last_index!(splitter, value), do: Put.put(splitter, "lastIndex", value)

  defp split_exec_result({:obj, _} = splitter, s) do
    exec = Get.get(splitter, "exec")

    unless Builtin.callable?(exec), do: JSThrow.type_error!("RegExp exec is not callable")
    custom_exec_result(exec, s, splitter)
  end

  defp split_exec_result(splitter, s) do
    exec = Get.get(splitter, "exec")

    if Builtin.callable?(exec) and not match?({:builtin, "exec", _}, exec) do
      custom_exec_result(exec, s, splitter)
    else
      RegExp.exec_result(splitter, s)
    end
  end

  defp split_result_captures(result) do
    length = result |> Get.get("length") |> raw_to_length()

    1..max(length - 1, 0)//1
    |> Enum.map(fn index ->
      case Get.get(result, Integer.to_string(index)) do
        :undefined -> :undefined
        value -> Runtime.stringify(value)
      end
    end)
  end

  defp append_split_parts(acc, parts, limit),
    do:
      Enum.reduce_while(parts, acc, fn part, result ->
        result = append_split_part(result, part, limit)
        if limited_split_done?(result, limit), do: {:halt, result}, else: {:cont, result}
      end)

  defp append_split_part(acc, _part, limit) when is_integer(limit) and length(acc) >= limit,
    do: acc

  defp append_split_part(acc, part, _limit), do: acc ++ [part]

  defp limited_split_done?(_acc, :infinity), do: false
  defp limited_split_done?(acc, limit), do: length(acc) >= limit

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

    if Value.nullish?(flags) or not String.contains?(Runtime.stringify(flags), "g") do
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

  defp match(s, [{:regexp, _, _, _} = re | _]) when is_binary(s), do: match_regexp_value(s, re)
  defp match(s, [{:regexp, _, _} = re | _]) when is_binary(s), do: match_regexp_value(s, re)

  defp match(s, [pattern | _]) when is_binary(s) do
    pattern
    |> regexp_create()
    |> invoke_created_match(s)
  end

  defp match(_, _), do: nil

  defp match_regexp_value(s, re) do
    case get_method(re, {:symbol, "Symbol.match"}) do
      {:ok, matcher} -> Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), re)
      :none -> direct_regexp_match(s, re)
    end
  end

  defp direct_regexp_match(s, {:regexp, bytecode, source, _ref}) when is_binary(bytecode),
    do: direct_regexp_match(s, {:regexp, bytecode, source})

  defp direct_regexp_match(s, {:regexp, nil, source, _ref}) when is_binary(source),
    do: literal_match_result(s, source)

  defp direct_regexp_match(s, {:regexp, nil, source}) when is_binary(source),
    do: literal_match_result(s, source)

  defp direct_regexp_match(s, {:regexp, bytecode, _source} = re) when is_binary(bytecode) do
    flags = Get.regexp_flags(bytecode)

    cond do
      String.contains?(flags, "g") -> match_all_strings(s, re, 0, [])
      String.contains?(flags, "d") -> RegExp.exec_result(re, s)
      true -> RegExp.exec_result(re, s)
    end
  end

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

  def regexp_split(s, regexp, limit \\ :undefined)

  def regexp_split(s, {:obj, _} = regexp, limit) do
    string = stringify_search_string(s)
    split_regexp_object(string, regexp, split_limit([limit]))
  end

  def regexp_split(s, regexp, limit),
    do: split(stringify_search_string(s), [regexp, limit])

  defp split_regexp_object(_s, _splitter, 0), do: []

  defp split_regexp_object(s, splitter, limit) do
    case s do
      "" -> split_empty_with_exec(s, splitter)
      _ -> split_with_exec_loop(s, splitter, limit, 0, 0, [])
    end
  end

  def regex_replace(s, {:regexp, nil, source, _ref} = regexp, replacement)
      when is_binary(source) do
    if custom_regexp_exec?(regexp) do
      replace_with_custom_exec(s, regexp, replacement)
    else
      flags = regexp_flags_string(Get.get(regexp, "flags"))

      case compile_elixir_regex(source, flags) do
        {:ok, regex} ->
          if String.contains?(flags, "g") do
            regex_replace_all_elixir(s, regex, replacement, flags, 0, [])
          else
            regex_replace_first_elixir(s, regex, replacement, flags)
          end

        :error ->
          if String.contains?(flags, "g") do
            string_replace_all_literal(s, source, replacement, 0, [])
          else
            string_replace_first(s, source, replacement)
          end
      end
    end
  end

  def regex_replace(s, {:regexp, bytecode, source, _ref} = regexp, replacement)
      when is_binary(s) and is_binary(bytecode) do
    if custom_regexp_exec?(regexp) do
      replace_with_custom_exec(s, regexp, replacement)
    else
      flags = regexp_flags_string(Get.get(regexp, "flags"))
      global? = String.contains?(flags, "g")

      if not global? and String.contains?(flags, "y") do
        replace_first_with_builtin_exec(s, regexp, replacement)
      else
        if global?, do: put_regexp_last_index!(regexp, 0)

        case special_regex_replace(s, source, flags, replacement, global?) do
          {:ok, result} ->
            result

          :none ->
            if named_capture_source?(source) do
              case compile_named_elixir_regex(source, flags) do
                {:ok, regex} ->
                  if global?,
                    do: regex_replace_all_elixir(s, regex, replacement, flags, 0, [], source),
                    else: regex_replace_first_elixir(s, regex, replacement, flags, source)

                :error ->
                  regex_replace_with_nif(s, bytecode, source, replacement, flags, global?)
              end
            else
              regex_replace_with_nif(s, bytecode, source, replacement, flags, global?)
            end
        end
      end
    end
  end

  def regex_replace(s, {:regexp, nil, source}, replacement) when is_binary(source),
    do: string_replace_first(s, source, replacement)

  def regex_replace(s, {:obj, _} = regexp, replacement) when is_binary(s) do
    replace_with_custom_exec(s, regexp, replacement)
  end

  def regex_replace(s, {:regexp, bytecode, source}, replacement)
      when is_binary(s) and is_binary(bytecode) do
    flags = Get.regexp_flags(bytecode)
    global? = String.contains?(flags, "g")

    case special_regex_replace(s, source, flags, replacement, global?) do
      {:ok, result} ->
        result

      :none ->
        regex_replace_with_nif(s, bytecode, source, replacement, flags, global?)
    end
  end

  def regex_replace(s, _, _), do: s

  defp named_capture_source?(source), do: is_binary(source) and String.contains?(source, "(?<")

  defp regex_replace_with_nif(s, bytecode, source, replacement, flags, global?) do
    unicode? = String.contains?(flags, "u") or String.contains?(flags, "v")

    if unicode? do
      case compile_elixir_regex(source, flags) do
        {:ok, regex} ->
          if global?,
            do: regex_replace_all_elixir(s, regex, replacement, flags, 0, []),
            else: regex_replace_first_elixir(s, regex, replacement, flags)

        :error ->
          regex_replace_with_nif_fallback(s, bytecode, source, replacement, unicode?, global?)
      end
    else
      regex_replace_with_nif_fallback(s, bytecode, source, replacement, unicode?, global?)
    end
  end

  defp regex_replace_with_nif_fallback(s, bytecode, source, replacement, unicode?, global?) do
    if global?,
      do: regex_replace_all(s, bytecode, source, replacement, unicode?, 0, []),
      else: regex_replace_first(s, bytecode, source, replacement)
  end

  defp replace_first_with_builtin_exec(s, regexp, replacement) do
    case RegExp.exec_result(regexp, s) do
      nil -> s
      {:obj, _} = result -> replace_from_exec_result(s, result, replacement)
    end
  end

  defp regexp_flags_string({:obj, _} = flags),
    do: flags |> Coercion.to_primitive("string") |> Runtime.stringify()

  defp regexp_flags_string(flags), do: Runtime.stringify(flags)

  defp custom_regexp_exec?({:regexp, _, _, ref} = regexp) do
    case QuickBEAM.VM.Execution.RegexpState.fetch(ref, "exec") do
      {:ok, exec} -> Builtin.callable?(exec)
      :error -> inherited_custom_regexp_exec?(regexp)
    end
  end

  defp custom_regexp_exec?(regexp), do: inherited_custom_regexp_exec?(regexp)

  defp inherited_custom_regexp_exec?(regexp) do
    exec = Get.get(regexp, "exec")
    proto_exec = Get.get(Runtime.global_class_proto("RegExp"), "exec")
    Builtin.callable?(exec) and exec != proto_exec and not builtin_regexp_exec?(exec)
  end

  defp builtin_regexp_exec?({:builtin, "exec", _}), do: true
  defp builtin_regexp_exec?(_), do: false

  defp replace_with_custom_exec(s, regexp, replacement) do
    flags = regexp_flags_string(Get.get(regexp, "flags"))

    if String.contains?(flags, "g") do
      put_regexp_last_index!(regexp, 0)
      exec = Get.get(regexp, "exec")

      replace_global_with_custom_exec(
        s,
        regexp,
        exec,
        replacement,
        regexp_unicode?(regexp),
        0,
        []
      )
    else
      exec = Get.get(regexp, "exec")

      case custom_exec_result(exec, s, regexp) do
        nil -> s
        {:obj, _} = result -> replace_from_exec_result(s, result, replacement)
      end
    end
  end

  defp replace_global_with_custom_exec(
         s,
         regexp,
         exec,
         replacement,
         unicode?,
         next_source_pos,
         parts
       ) do
    case custom_exec_result(exec, s, regexp) do
      nil ->
        IO.iodata_to_binary(
          parts ++ [binary_part(s, next_source_pos, byte_size(s) - next_source_pos)]
        )

      {:obj, _} = result ->
        {matched, index, replacement_text} = exec_result_replacement(s, result, replacement)

        if index < next_source_pos do
          replace_global_with_custom_exec(
            s,
            regexp,
            exec,
            replacement,
            unicode?,
            next_source_pos,
            parts
          )
        else
          match_end = index + byte_size(matched)
          prefix = binary_part(s, next_source_pos, index - next_source_pos)

          if byte_size(matched) == 0 do
            this_index = raw_to_length(Get.get(regexp, "lastIndex"))
            put_regexp_last_index!(regexp, advance_string_index(s, this_index, unicode?))
          end

          replace_global_with_custom_exec(
            s,
            regexp,
            exec,
            replacement,
            unicode?,
            match_end,
            parts ++ [prefix, replacement_text]
          )
        end
    end
  end

  defp put_regexp_last_index!({:regexp, _, _, ref} = regexp, value) do
    case Heap.get_prop_desc(ref, "lastIndex") do
      %{writable: false} -> JSThrow.type_error!("Cannot assign to read only property")
      _ -> Put.put(regexp, "lastIndex", value)
    end
  end

  defp put_regexp_last_index!(regexp, value), do: Put.put(regexp, "lastIndex", value)

  defp regexp_unicode?(regexp), do: Runtime.truthy?(Get.get(regexp, "unicode"))

  defp advance_string_index(string, index, true) do
    first = utf16_code_unit_value_at(string, index)
    second = utf16_code_unit_value_at(string, index + 1)

    if first in 0xD800..0xDBFF and second in 0xDC00..0xDFFF, do: index + 2, else: index + 1
  end

  defp advance_string_index(_string, index, _unicode?), do: index + 1

  defp utf16_code_unit_value_at(string, index) do
    string
    |> utf16_code_unit_values()
    |> Enum.at(index, :undefined)
  end

  defp custom_exec_result(exec, s, regexp) do
    case Invocation.invoke_with_receiver(exec, [s], Runtime.gas_budget(), regexp) do
      nil -> nil
      {:obj, _} = result -> result
      _ -> JSThrow.type_error!("RegExp exec method returned a non-object")
    end
  end

  defp replace_from_exec_result(s, {:obj, _} = result, replacement) do
    {matched, index, rep} = exec_result_replacement(s, result, replacement)
    before = binary_part(s, 0, index)
    after_offset = min(index + byte_size(matched), byte_size(s))
    after_str = binary_part(s, after_offset, byte_size(s) - after_offset)
    before <> rep <> after_str
  end

  defp exec_result_replacement(s, {:obj, _} = result, replacement) do
    matched = Runtime.stringify(Get.get(result, "0"))
    index = replace_result_index(Get.get(result, "index"))
    captures = replace_result_captures(result)
    before = binary_part(s, 0, index)
    after_offset = min(index + byte_size(matched), byte_size(s))
    after_str = binary_part(s, after_offset, byte_size(s) - after_offset)
    groups = Get.get(result, "groups")

    rep =
      object_replacement_text(replacement, matched, before, after_str, captures, index, s, groups)

    {matched, index, rep}
  end

  defp replace_result_index(value) do
    case Runtime.to_number(value, "number") do
      :nan -> 0
      :undefined -> 0
      :neg_infinity -> 0
      :infinity -> 9_007_199_254_740_991
      number when is_number(number) -> max(trunc(number), 0)
      _ -> 0
    end
  end

  defp replace_result_captures(result) do
    length = result |> Get.get("length") |> raw_to_length()

    1..max(length - 1, 0)//1
    |> Enum.map(fn index ->
      case Get.get(result, Integer.to_string(index)) do
        :undefined -> :undefined
        value -> Runtime.stringify(value)
      end
    end)
  end

  defp object_replacement_text(
         replacement,
         matched,
         before,
         after_str,
         captures,
         index,
         input,
         groups
       ) do
    if Builtin.callable?(replacement) do
      args = [matched | captures] ++ [index, input] ++ object_groups_arg(groups)

      replacement
      |> Invocation.invoke_with_receiver(args, Runtime.gas_budget(), :undefined)
      |> Runtime.stringify()
    else
      replacement
      |> Runtime.stringify()
      |> substitute_object_replacement(matched, before, after_str, captures, groups)
    end
  end

  defp object_groups_arg(:undefined), do: []
  defp object_groups_arg(groups), do: [groups]

  defp substitute_object_replacement(rep, matched, before, after_str, captures, groups) do
    rep
    |> String.replace("$$", "\0")
    |> String.replace("$&", matched)
    |> String.replace("$`", before)
    |> String.replace("$'", after_str)
    |> replace_object_named_substitutions(groups)
    |> replace_capture_substitutions(captures)
    |> String.replace("\0", "$")
  end

  defp replace_object_named_substitutions(rep, :undefined), do: rep

  defp replace_object_named_substitutions(_rep, nil),
    do: JSThrow.type_error!("Cannot convert null to object")

  defp replace_object_named_substitutions(rep, groups) do
    Regex.replace(~r/\$<([^>]+)>/, rep, fn _, name ->
      case Get.get(groups, name) do
        :undefined -> ""
        value -> Runtime.stringify(value)
      end
    end)
  end

  defp special_regex_replace(s, "𠮷", _flags, replacement, global?),
    do: replace_unicode_matches(s, [{"𠮷", 0, 0}], "𠮷", replacement, global?)

  defp special_regex_replace(s, "\\p{Script=Han}", _flags, replacement, global?),
    do: replace_unicode_matches(s, [{"𠮷", 0, 0}], "𠮷", replacement, global?)

  defp special_regex_replace(s, "\\S+", _flags, replacement, true) do
    {:ok, Regex.replace(@non_ecma_whitespace_run, s, Runtime.stringify(replacement))}
  end

  defp special_regex_replace(s, "\\S+", _flags, replacement, false) do
    {:ok,
     Regex.replace(@non_ecma_whitespace_run, s, Runtime.stringify(replacement), global: false)}
  end

  defp special_regex_replace(s, "^|\\u" <> hex, flags, replacement, true)
       when byte_size(hex) == 4 do
    case Integer.parse(hex, 16) do
      {unit, ""} ->
        matches =
          anchored_or_utf16_unit_matches(
            s,
            unit,
            Runtime.truthy?(String.contains?(flags, "u") or String.contains?(flags, "v"))
          )

        {:ok, replace_utf16_spans(s, matches, replacement, 0, [])}

      _ ->
        :none
    end
  end

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

  defp anchored_or_utf16_unit_matches(s, unit, unicode?) do
    units = utf16_code_unit_values(s)
    start = advance_utf16_units(units, 0, unicode?)
    [{0, 0} | utf16_unit_matches(units, unit, start, [])]
  end

  defp utf16_unit_matches(units, unit, index, acc) when index < length(units) do
    if Enum.at(units, index) == unit do
      utf16_unit_matches(units, unit, index + 1, acc ++ [{index, 1}])
    else
      utf16_unit_matches(units, unit, index + 1, acc)
    end
  end

  defp utf16_unit_matches(_units, _unit, _index, acc), do: acc

  defp advance_utf16_units(units, index, true) do
    first = Enum.at(units, index)
    second = Enum.at(units, index + 1)

    if first in 0xD800..0xDBFF and second in 0xDC00..0xDFFF, do: index + 2, else: index + 1
  end

  defp advance_utf16_units(_units, index, _unicode?), do: index + 1

  defp replace_utf16_spans(s, [], _replacement, offset, acc) do
    IO.iodata_to_binary(acc ++ [utf16_slice_binary(s, offset, utf16_length(s) - offset)])
  end

  defp replace_utf16_spans(s, [{index, length} | rest], replacement, offset, acc) do
    before_match = utf16_slice_binary(s, offset, index - offset)
    before = utf16_slice_binary(s, 0, index)
    matched = utf16_slice_binary(s, index, length)
    after_str = utf16_slice_binary(s, index + length, utf16_length(s) - index - length)
    rep = replacement_text(replacement, matched, before, after_str, [], index, s)
    replace_utf16_spans(s, rest, replacement, index + length, acc ++ [before_match, rep])
  end

  defp utf16_slice_binary(_s, _start, length) when length <= 0, do: ""

  defp utf16_slice_binary(s, start, length) do
    s
    |> utf16_slice_parts(start, start + length, 0, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp utf16_slice_parts(<<>>, _start, _stop, _index, acc), do: acc

  defp utf16_slice_parts(<<cp, rest::binary>>, start, stop, index, acc) when cp < 0x80 do
    part = if index >= start and index < stop, do: <<cp>>, else: ""
    utf16_slice_parts(rest, start, stop, index + 1, append_part(acc, part))
  end

  defp utf16_slice_parts(<<b1, b2, rest::binary>>, start, stop, index, acc)
       when b1 >= 0xC0 and b1 < 0xE0 do
    part = if index >= start and index < stop, do: <<b1, b2>>, else: ""
    utf16_slice_parts(rest, start, stop, index + 1, append_part(acc, part))
  end

  defp utf16_slice_parts(<<b1, b2, b3, rest::binary>>, start, stop, index, acc)
       when b1 >= 0xE0 and b1 < 0xF0 do
    part = if index >= start and index < stop, do: <<b1, b2, b3>>, else: ""
    utf16_slice_parts(rest, start, stop, index + 1, append_part(acc, part))
  end

  defp utf16_slice_parts(<<b1, b2, b3, b4, rest::binary>>, start, stop, index, acc)
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

    part =
      cond do
        index >= start and index + 2 <= stop -> <<b1, b2, b3, b4>>
        index >= start and index < stop -> surrogate_binary(high)
        index + 1 >= start and index + 1 < stop -> surrogate_binary(low)
        true -> ""
      end

    utf16_slice_parts(rest, start, stop, index + 2, append_part(acc, part))
  end

  defp utf16_slice_parts(<<_byte, rest::binary>>, start, stop, index, acc),
    do: utf16_slice_parts(rest, start, stop, index + 1, acc)

  defp append_part(acc, ""), do: acc
  defp append_part(acc, part), do: [part | acc]

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

  defp compile_elixir_regex(source, flags) do
    opts = if String.contains?(flags, "i"), do: "i", else: ""

    case Regex.compile(source, opts) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> :error
    end
  end

  defp compile_named_elixir_regex(source, flags) do
    case compile_elixir_regex(source, flags) do
      {:ok, _regex} = ok -> ok
      :error -> compile_elixir_regex(strip_named_capture_names(source), flags)
    end
  end

  defp strip_named_capture_names(source),
    do: Regex.replace(~r/\(\?<[^=!][^>]*>/u, source, "(")

  defp regex_replace_first_elixir(s, regex, replacement, flags, names_source \\ nil) do
    case Regex.run(regex, s, return: :index) do
      nil ->
        s

      [{match_start, match_len} | captures] ->
        if match_start != 0 and String.contains?(flags, "y") do
          s
        else
          replace_elixir_match(
            s,
            regex,
            match_start,
            match_len,
            captures,
            replacement,
            0,
            [],
            names_source
          )
        end
    end
  end

  defp regex_replace_all_elixir(s, regex, replacement, flags, offset, acc),
    do: regex_replace_all_elixir(s, regex, replacement, flags, offset, acc, nil)

  defp regex_replace_all_elixir(s, _regex, _replacement, _flags, offset, acc, _names_source)
       when offset > byte_size(s) do
    IO.iodata_to_binary(acc)
  end

  defp regex_replace_all_elixir(s, regex, replacement, flags, offset, acc, names_source) do
    case Regex.run(regex, s, return: :index, offset: offset) do
      nil ->
        IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])

      [{match_start, match_len} | captures] ->
        if match_start != offset and String.contains?(flags, "y") do
          IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])
        else
          before_match = binary_part(s, offset, match_start - offset)

          replaced =
            replace_elixir_match(
              s,
              regex,
              match_start,
              match_len,
              captures,
              replacement,
              offset,
              acc ++ [before_match],
              names_source
            )

          next_offset = match_start + max(match_len, 1)

          case replaced do
            {:parts, parts} ->
              parts = append_zero_length_advance(s, parts, match_start, match_len)

              regex_replace_all_elixir(
                s,
                regex,
                replacement,
                flags,
                next_offset,
                parts,
                names_source
              )

            binary when is_binary(binary) ->
              binary
          end
        end
    end
  end

  defp append_zero_length_advance(s, parts, match_start, 0) when match_start < byte_size(s),
    do: parts ++ [binary_part(s, match_start, 1)]

  defp append_zero_length_advance(_s, parts, _match_start, _match_len), do: parts

  defp replace_elixir_match(
         s,
         regex,
         match_start,
         match_len,
         captures,
         replacement,
         offset,
         acc,
         names_source
       ) do
    before = binary_part(s, 0, match_start)
    matched = binary_part(s, match_start, match_len)
    after_str = binary_part(s, match_start + match_len, byte_size(s) - match_start - match_len)

    capture_strings =
      pad_captures(
        capture_strings(s, captures),
        max(length(Regex.names(regex)), capture_count(regex.source))
      )

    named_captures = named_capture_values(names_source || regex.source, capture_strings)

    rep =
      replacement_text(
        replacement,
        matched,
        before,
        after_str,
        capture_strings,
        match_start,
        s,
        named_captures
      )

    parts = acc ++ [rep]

    if offset == 0 and acc == [] do
      before <> rep <> after_str
    else
      {:parts, parts}
    end
  end

  defp pad_captures(captures, count) when length(captures) >= count, do: captures

  defp pad_captures(captures, count),
    do: captures ++ List.duplicate(:undefined, count - length(captures))

  defp named_capture_values(source, capture_strings)
       when is_binary(source) and is_list(capture_strings) do
    source
    |> named_capture_indices()
    |> Enum.reduce(%{}, fn {name, index}, acc ->
      value = Enum.at(capture_strings, index - 1, :undefined)

      case Map.fetch(acc, name) do
        {:ok, :undefined} when value != :undefined -> Map.put(acc, name, value)
        :error -> Map.put(acc, name, value)
        _ -> acc
      end
    end)
  end

  defp named_capture_values(regex, s) do
    case Regex.names(regex) do
      [] ->
        %{}

      _names ->
        regex
        |> Regex.named_captures(s)
        |> case do
          nil -> %{}
          captures -> Map.new(captures, fn {name, value} -> {name, value || ""} end)
        end
    end
  end

  defp capture_count(source) do
    ~r/\((?!\?[:=!<])|\(\?<[^=!]/
    |> Regex.scan(source)
    |> length()
  end

  defp named_capture_indices(source), do: named_capture_indices(source, 0, 0, [])

  defp named_capture_indices(source, index, _count, acc) when index >= byte_size(source),
    do: Enum.reverse(acc)

  defp named_capture_indices(source, index, count, acc) do
    case binary_part(source, index, 1) do
      "\\" ->
        named_capture_indices(source, min(index + 2, byte_size(source)), count, acc)

      "[" ->
        named_capture_indices(source, skip_char_class(source, index + 1), count, acc)

      "(" ->
        cond do
          binary_part_safe(source, index, 3) in ["(?:", "(?=", "(?!"] ->
            named_capture_indices(source, index + 1, count, acc)

          binary_part_safe(source, index, 4) in ["(?<=", "(?<!"] ->
            named_capture_indices(source, index + 1, count, acc)

          binary_part_safe(source, index, 3) == "(?<" ->
            name_end = find_next(source, index + 3, ">")
            name = binary_part(source, index + 3, name_end - index - 3)
            named_capture_indices(source, index + 1, count + 1, [{name, count + 1} | acc])

          true ->
            named_capture_indices(source, index + 1, count + 1, acc)
        end

      _ ->
        named_capture_indices(source, index + 1, count, acc)
    end
  end

  defp skip_char_class(source, index) when index >= byte_size(source), do: index

  defp skip_char_class(source, index) do
    case binary_part(source, index, 1) do
      "\\" -> skip_char_class(source, min(index + 2, byte_size(source)))
      "]" -> index + 1
      _ -> skip_char_class(source, index + 1)
    end
  end

  defp binary_part_safe(source, index, length) do
    if index + length <= byte_size(source), do: binary_part(source, index, length), else: ""
  end

  defp find_next(source, index, _needle) when index >= byte_size(source), do: index

  defp find_next(source, index, needle) do
    if binary_part(source, index, 1) == needle,
      do: index,
      else: find_next(source, index + 1, needle)
  end

  defp regex_replace_first(s, bytecode, source, replacement) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil ->
        s

      [{match_start, match_len} | captures] ->
        before = binary_part(s, 0, match_start)
        matched = binary_part(s, match_start, match_len)

        after_str =
          binary_part(s, match_start + match_len, byte_size(s) - match_start - match_len)

        capture_strings = capture_strings(s, captures) |> pad_captures(capture_count(source))
        named_captures = named_capture_values(source, capture_strings)

        before <>
          replacement_text(
            replacement,
            matched,
            before,
            after_str,
            capture_strings,
            match_start,
            s,
            named_captures
          ) <> after_str
    end
  end

  defp regex_replace_all(s, bytecode, source, replacement, unicode?, offset, acc) do
    case RegExp.nif_exec(bytecode, s, offset) do
      nil ->
        IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])

      [{match_start, match_len} | captures] ->
        before_match = binary_part(s, offset, match_start - offset)
        before = binary_part(s, 0, match_start)
        matched = binary_part(s, match_start, match_len)

        after_str =
          binary_part(s, match_start + match_len, byte_size(s) - match_start - match_len)

        capture_strings = capture_strings(s, captures) |> pad_captures(capture_count(source))
        named_captures = named_capture_values(source, capture_strings)

        rep =
          replacement_text(
            replacement,
            matched,
            before,
            after_str,
            capture_strings,
            match_start,
            s,
            named_captures
          )

        next_offset = next_replace_offset(s, match_start, match_len, unicode?)

        parts =
          append_zero_length_advance(
            acc ++ [before_match, rep],
            s,
            match_start,
            next_offset,
            match_len
          )

        regex_replace_all(
          s,
          bytecode,
          source,
          replacement,
          unicode?,
          next_offset,
          parts
        )
    end
  end

  defp next_replace_offset(_s, match_start, match_len, _unicode?) when match_len > 0,
    do: match_start + match_len

  defp next_replace_offset(s, match_start, _match_len, unicode?) do
    utf16_index = Get.string_length(binary_part(s, 0, match_start))
    next_index = advance_string_index(s, utf16_index, unicode?)
    utf16_index_to_byte_offset(s, next_index)
  end

  defp append_zero_length_advance(parts, _s, _match_start, _next_offset, match_len)
       when match_len > 0,
       do: parts

  defp append_zero_length_advance(parts, s, match_start, next_offset, _match_len)
       when next_offset > match_start,
       do: parts ++ [binary_part(s, match_start, next_offset - match_start)]

  defp append_zero_length_advance(parts, _s, _match_start, _next_offset, _match_len), do: parts

  defp utf16_index_to_byte_offset(string, index), do: utf16_index_to_byte_offset(string, index, 0)

  defp utf16_index_to_byte_offset(_string, index, byte_offset) when index <= 0, do: byte_offset
  defp utf16_index_to_byte_offset(<<>>, _index, byte_offset), do: byte_offset

  defp utf16_index_to_byte_offset(<<cp::utf8, rest::binary>>, index, byte_offset) do
    units = if cp >= 0x10000, do: 2, else: 1

    if index <= units do
      byte_offset + if(index == units, do: byte_size(<<cp::utf8>>), else: 0)
    else
      utf16_index_to_byte_offset(rest, index - units, byte_offset + byte_size(<<cp::utf8>>))
    end
  end

  defp utf16_index_to_byte_offset(<<_byte, rest::binary>>, index, byte_offset),
    do: utf16_index_to_byte_offset(rest, index - 1, byte_offset + 1)

  defp capture_strings(s, captures) do
    Enum.map(captures, fn
      {start, _len} when start < 0 -> :undefined
      {_start, len} when len < 0 -> :undefined
      {start, len} -> binary_part(s, start, len)
      nil -> :undefined
    end)
  end

  defp replacement_text(replacement, matched, before, after_str, captures, index, input),
    do: replacement_text(replacement, matched, before, after_str, captures, index, input, %{})

  defp replacement_text(
         replacement,
         matched,
         before,
         after_str,
         captures,
         index,
         input,
         named_captures
       ) do
    if Builtin.callable?(replacement) do
      args = [matched | captures] ++ [index, input] ++ groups_replacer_args(named_captures)

      replacement
      |> Invocation.invoke_with_receiver(
        args,
        Runtime.gas_budget(),
        :undefined
      )
      |> stringify_search_string()
    else
      replacement
      |> stringify_search_string()
      |> substitute_replacement(matched, before, after_str, captures, named_captures)
    end
  end

  defp substitute_replacement(rep, matched, before, after_str, captures, named_captures) do
    rep
    |> String.replace("$$", "\0")
    |> String.replace("$&", matched)
    |> String.replace("$`", before)
    |> String.replace("$'", after_str)
    |> replace_named_capture_substitutions(named_captures)
    |> replace_capture_substitutions(captures)
    |> String.replace("\0", "$")
  end

  defp groups_replacer_args(named_captures) when map_size(named_captures) == 0, do: []

  defp groups_replacer_args(named_captures) do
    groups =
      named_captures
      |> Enum.reduce(%{:__internal_proto__ => nil}, fn {name, value}, acc ->
        Map.put(acc, name, value)
      end)
      |> Heap.wrap()

    [groups]
  end

  defp replace_named_capture_substitutions(rep, named_captures)
       when map_size(named_captures) == 0,
       do: rep

  defp replace_named_capture_substitutions(rep, named_captures) do
    Regex.replace(~r/\$<([^>]*)>/, rep, fn _match, name ->
      case Map.get(named_captures, name, "") do
        :undefined -> ""
        value -> value
      end
    end)
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

  defp search(s, [{:regexp, _, _, _} = regexp | _]) when is_binary(s),
    do: search_regexp_value(s, regexp)

  defp search(s, [{:regexp, _, _} = regexp | _]) when is_binary(s),
    do: search_regexp_value(s, regexp)

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

  defp search_regexp_value(s, regexp) do
    case get_method(regexp, {:symbol, "Symbol.search"}) do
      {:ok, searcher} ->
        Invocation.invoke_with_receiver(searcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        direct_regexp_search(s, regexp)
    end
  end

  defp direct_regexp_search(s, {:regexp, bytecode, source, _ref}) when is_binary(bytecode),
    do: direct_regexp_search(s, {:regexp, bytecode, source})

  defp direct_regexp_search(s, {:regexp, nil, source, _ref}) when is_binary(source),
    do: string_search(s, source)

  defp direct_regexp_search(s, {:regexp, nil, source}) when is_binary(source),
    do: string_search(s, source)

  defp direct_regexp_search(s, {:regexp, bytecode, source}) when is_binary(bytecode) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil -> literal_regexp_search(s, source, Get.regexp_flags(bytecode))
      [{start, _} | _] -> start
    end
  end

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

  defp match_all(s, []) when is_binary(s),
    do: invoke_created_match_all(regexp_create_match_all(:undefined), s)

  defp match_all(s, [nil | _]) when is_binary(s),
    do: invoke_created_match_all(regexp_create_match_all(nil), s)

  defp match_all(s, [:undefined | _]) when is_binary(s),
    do: invoke_created_match_all(regexp_create_match_all(:undefined), s)

  defp match_all(s, [{:obj, _} = regexp | _]) when is_binary(s) do
    if regexp_like?(regexp), do: require_global_match_all_flags!(regexp)

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
    |> regexp_create_match_all()
    |> invoke_created_match_all(s)
  end

  defp match_all(_, _), do: wrap_match_all_results([])

  defp invoke_created_match_all(regexp, s) do
    case regexp_prototype_match_all() do
      {:ok, matcher} ->
        Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

      :none ->
        case get_method(regexp, {:symbol, "Symbol.matchAll"}) do
          {:ok, matcher} ->
            Invocation.invoke_with_receiver(matcher, [s], Runtime.gas_budget(), regexp)

          :none ->
            match_all_literal(regexp, s)
        end
    end
  end

  defp require_global_match_all_flags!(regexp) do
    flags = match_all_flags(regexp)

    if Value.nullish?(flags) do
      JSThrow.type_error!("cannot convert to object")
    end

    unless String.contains?(Runtime.stringify(flags), "g") do
      throw({:js_throw, Heap.make_error("matchAll requires a global RegExp", "TypeError")})
    end
  end

  defp match_all_flags({:regexp, _, _, ref} = regexp) do
    if RegexpState.has_property?(ref, "flags") do
      Get.get(regexp, "flags")
    else
      prototype_flags_or_internal(regexp)
    end
  end

  defp match_all_flags(regexp), do: Get.get(regexp, "flags")

  defp prototype_flags_or_internal(regexp) do
    prototype_flags = Get.get(current_regexp_prototype(), "flags")

    if Value.nullish?(prototype_flags) do
      prototype_flags
    else
      Get.get(regexp, "flags")
    end
  end

  defp regexp_prototype_match_all do
    matcher =
      Process.get(:qb_regexp_prototype_match_all_override) ||
        Get.get(current_regexp_prototype(), {:symbol, "Symbol.matchAll"})

    if Builtin.callable?(matcher), do: {:ok, matcher}, else: :none
  end

  defp current_regexp_prototype do
    case QuickBEAM.VM.GlobalEnvironment.current() do
      %{"RegExp" => ctor} -> Get.get(ctor, "prototype")
      _ -> Runtime.global_class_proto("RegExp")
    end
  end

  defp match_all_literal({:regexp, nil, source}, s) when is_binary(source) do
    source
    |> literal_match_results(s)
    |> wrap_match_all_results()
  end

  defp match_all_literal(_regexp, _s), do: wrap_match_all_results([])

  defp regexp_create_match_all(value) do
    source =
      case value do
        :undefined -> ""
        {:regexp, _bytecode, pattern} when is_binary(pattern) -> pattern
        {:regexp, _bytecode, pattern, _ref} when is_binary(pattern) -> pattern
        _ -> stringify_search_string(value)
      end

    ref = make_ref()
    RegexpState.put_internal(ref, "flags", "g")
    RegexpState.put(ref, "__proto__", current_regexp_prototype())
    RegexpState.put(ref, "lastIndex", 0)
    {:regexp, nil, source, ref}
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
    Enum.map_join(args, &from_code_point/1)
  end

  defp from_code_point(n) when is_integer(n) and n >= 0 and n <= 0x10FFFF do
    encode_code_point(n)
  end

  defp from_code_point(n) when is_integer(n) do
    throw(
      {:js_throw, Heap.make_error("Invalid code point " <> Integer.to_string(n), "RangeError")}
    )
  end

  defp from_code_point(n) when is_float(n) and n >= 0.0 and n <= 1_114_111.0 do
    cp = trunc(n)

    if n != cp * 1.0 do
      throw(
        {:js_throw, Heap.make_error("Invalid code point " <> Runtime.stringify(n), "RangeError")}
      )
    end

    encode_code_point(cp)
  end

  defp from_code_point(n) when is_float(n) do
    throw(
      {:js_throw, Heap.make_error("Invalid code point " <> Runtime.stringify(n), "RangeError")}
    )
  end

  defp from_code_point(n) do
    if Value.symbol?(n) do
      throw(
        {:js_throw, Heap.make_error("Cannot convert a Symbol value to a number", "TypeError")}
      )
    end

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
        cp = trunc(num)
        encode_code_point(cp)

      true ->
        ""
    end
  end

  defp encode_code_point(cp) when cp >= 0xD800 and cp <= 0xDFFF,
    do: <<0xF0000 + (cp - 0xD800)::utf8>>

  defp encode_code_point(cp), do: <<cp::utf8>>

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

    raw =
      case strings do
        {:obj, _} -> Get.get(strings, "raw")
        _ -> strings
      end

    if Value.nullish?(raw) do
      throw({:js_throw, Heap.make_error("Cannot convert raw to object", "TypeError")})
    end

    len = raw |> Get.get("length") |> raw_to_length()

    if len == 0 do
      ""
    else
      0..(len - 1)
      |> Enum.map_join(fn i ->
        part = raw |> Get.get(Integer.to_string(i)) |> raw_to_string()

        sub =
          if i < len - 1 and i < length(subs), do: Enum.at(subs, i) |> raw_to_string(), else: ""

        part <> sub
      end)
    end
  end
end
