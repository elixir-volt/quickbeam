defmodule QuickBEAM.VM.Runtime.RegExp do
  @moduledoc "JS `RegExp` built-in: `test`, `exec`, `toString`, and NIF-backed regex matching against JS bytecode patterns."

  use QuickBEAM.VM.Builtin
  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0]

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.{Builtin, Heap, Invocation, JSThrow, Runtime}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Get, PropertyDescriptor, Put}
  alias QuickBEAM.VM.Runtime.String, as: JSString

  static "escape", length: 1, constructable: false do
    case args do
      [value | _] when is_binary(value) -> regexp_escape(value)
      _ -> JSThrow.type_error!("RegExp.escape requires a string")
    end
  end

  proto "test" do
    test(this, args)
  end

  proto "exec" do
    exec(this, args)
  end

  def exec_result(regexp, string) when is_binary(string), do: exec(regexp, [string])

  proto "toString" do
    regexp_to_string(this)
  end

  def proto_property({:symbol, "Symbol.match"}) do
    {:builtin, "[Symbol.match]", fn args, this -> regexp_match(this, args) end}
  end

  def proto_property({:symbol, "Symbol.matchAll"}) do
    {:builtin, "[Symbol.matchAll]", fn args, this -> regexp_match_all(this, args) end}
  end

  def proto_property({:symbol, "Symbol.replace"}) do
    {:builtin, "[Symbol.replace]", fn args, this -> regexp_replace(this, args) end}
  end

  def proto_property({:symbol, "Symbol.search"}) do
    {:builtin, "[Symbol.search]", fn args, this -> regexp_search(this, args) end}
  end

  def proto_accessor("source"),
    do: {:accessor, {:builtin, "get source", fn _, this -> regexp_source(this) end}, nil}

  def proto_accessor("global"), do: regexp_flag_accessor("global", "g")
  def proto_accessor("ignoreCase"), do: regexp_flag_accessor("ignoreCase", "i")
  def proto_accessor("multiline"), do: regexp_flag_accessor("multiline", "m")
  def proto_accessor(_), do: :undefined

  @doc "Executes compiled QuickJS regexp bytecode against a string via the native regexp engine."
  def nif_exec(bytecode, str, last_index) when is_binary(bytecode) and is_binary(str) do
    raw_bc = utf8_to_latin1(bytecode)
    # Unicode regexes expect UTF-8 input; non-unicode expect Latin-1
    flags =
      if byte_size(bytecode) >= 2,
        do: :binary.at(bytecode, 0) + :binary.at(bytecode, 1) * 256,
        else: 0

    is_unicode = Bitwise.band(flags, 0x10) != 0
    raw_str = if is_unicode, do: str, else: utf8_to_latin1(str)

    case QuickBEAM.Native.regexp_exec(raw_bc, raw_str, last_index) do
      nil ->
        nil

      captures when is_list(captures) ->
        Enum.map(captures, fn
          {start, end_off} -> {start, end_off - start}
          nil -> nil
        end)
    end
  end

  def nif_exec(_, _, _), do: nil

  defp test({:regexp, _bytecode, "^\\s+$", _ref}, [s | _]) when is_binary(s) do
    s != "" and all_ecma_whitespace?(s)
  end

  defp test({:regexp, _bytecode, "^\\s+$"}, [s | _]) when is_binary(s) do
    s != "" and all_ecma_whitespace?(s)
  end

  defp test({:regexp, _bytecode, "\\S", _ref}, [s | _]) when is_binary(s) do
    any_non_ecma_whitespace?(s)
  end

  defp test({:regexp, _bytecode, "\\S"}, [s | _]) when is_binary(s) do
    any_non_ecma_whitespace?(s)
  end

  defp test({:regexp, bytecode, "^.$", ref}, [s | _]) when is_binary(s) do
    single_dot_match?(s, regexp_flags(bytecode, ref))
  end

  defp test({:regexp, bytecode, "^.$"}, [s | _]) when is_binary(s) do
    single_dot_match?(s, Get.regexp_flags(bytecode))
  end

  defp test({:regexp, _bytecode, "^[$_a-zA-Z][$_a-zA-Z0-9]*$", _ref}, [s | _])
       when is_binary(s) do
    ascii_identifier?(s)
  end

  defp test({:regexp, _bytecode, "^[$_a-zA-Z][$_a-zA-Z0-9]*$"}, [s | _])
       when is_binary(s) do
    ascii_identifier?(s)
  end

  defp test({:regexp, bytecode, _source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    nif_exec(bytecode, s, 0) != nil
  end

  defp test({:regexp, bytecode, _source, _ref}, [s | _])
       when is_binary(bytecode) and is_binary(s) do
    nif_exec(bytecode, s, 0) != nil
  end

  defp test(_, _), do: false

  defp ascii_identifier?(<<first::utf8, rest::binary>>) do
    ascii_identifier_start?(first) and ascii_identifier_rest?(rest)
  end

  defp ascii_identifier?(""), do: false

  defp ascii_identifier_rest?(<<>>), do: true

  defp ascii_identifier_rest?(<<char::utf8, rest::binary>>) do
    ascii_identifier_part?(char) and ascii_identifier_rest?(rest)
  end

  defp ascii_identifier_start?(char),
    do: char in ?a..?z or char in ?A..?Z or char in [?$, ?_]

  defp ascii_identifier_part?(char), do: ascii_identifier_start?(char) or char in ?0..?9

  defp all_ecma_whitespace?(string) do
    string
    |> String.to_charlist()
    |> Enum.all?(&ecma_whitespace?/1)
  end

  defp any_non_ecma_whitespace?(string) do
    string
    |> String.to_charlist()
    |> Enum.any?(&(not ecma_whitespace?(&1)))
  end

  defp ecma_whitespace?(cp),
    do:
      cp in [
        0x0009,
        0x000A,
        0x000B,
        0x000C,
        0x000D,
        0x0020,
        0x00A0,
        0x1680,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        0xFEFF
      ] or cp in 0x2000..0x200A

  defp single_dot_match?(string, flags) do
    dot_matches = String.contains?(flags, "s") or string not in ["\n", "\r", "\u2028", "\u2029"]

    single =
      if String.contains?(flags, "u") or String.contains?(flags, "v") do
        String.length(string) == 1 or lone_surrogate_wtf8?(string)
      else
        Get.string_length(string) == 1 or lone_surrogate_wtf8?(string)
      end

    dot_matches and single
  end

  defp lone_surrogate_wtf8?(<<0xED, high, low>>) when high in 0xA0..0xBF and low in 0x80..0xBF,
    do: true

  defp lone_surrogate_wtf8?(_), do: false

  defp exec({:regexp, bytecode, "(?<=^(\\w+))def", ref} = regexp, [s | _])
       when is_binary(bytecode) and is_binary(s) do
    flags = regexp_flags(bytecode, ref)

    if String.contains?(flags, "g") do
      exec_global_prefix_lookbehind_def(regexp, s)
    else
      exec({:regexp, bytecode, "(?<=^(\\w+))def"}, [s])
    end
  end

  defp exec({:regexp, bytecode, "\\Bdef", ref} = regexp, [s | _])
       when is_binary(bytecode) and is_binary(s) do
    flags = regexp_flags(bytecode, ref)

    if String.contains?(flags, "g") do
      exec_global_non_boundary_def(regexp, s)
    else
      exec({:regexp, bytecode, "\\Bdef"}, [s])
    end
  end

  defp exec({:regexp, bytecode, source, ref} = regexp, [s | _])
       when is_binary(bytecode) and is_binary(s) and source in ["\\w", "\\W"] do
    flags = regexp_flags(bytecode, ref)

    if String.contains?(flags, "g") do
      exec_global_ascii_word(regexp, source, s)
    else
      exec({:regexp, bytecode, source}, [s])
    end
  end

  defp exec({:regexp, bytecode, source, _ref}, args),
    do: exec({:regexp, bytecode, source}, args)

  defp exec({:regexp, nil, source}, [s | _]) when is_binary(source) and is_binary(s),
    do: literal_exec(s, source)

  defp exec({:regexp, bytecode, source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    case decoded_simple_escape(source) do
      literal when is_binary(literal) ->
        literal_exec_decoded(s, literal)

      :error ->
        exec_nif(bytecode, source, Get.regexp_flags(bytecode), s)
    end
  end

  defp exec(_, _), do: nil

  defp exec_global_prefix_lookbehind_def(regexp, string) do
    start_index = max(Runtime.to_int(Get.get(regexp, "lastIndex")), 0)

    case Regex.run(~r/def/, binary_part(string, start_index, byte_size(string) - start_index),
           return: :index
         ) do
      [{relative, 3}] ->
        index = start_index + relative
        prefix = binary_part(string, 0, index)

        if Regex.match?(~r/^\w+$/, prefix) do
          Put.put(regexp, "lastIndex", index + 3)
          exec_result(["def", prefix], index, string)
        else
          Put.put(regexp, "lastIndex", 0)
          nil
        end

      _ ->
        Put.put(regexp, "lastIndex", 0)
        nil
    end
  end

  defp exec_global_non_boundary_def(regexp, string) do
    start_index = max(Runtime.to_int(Get.get(regexp, "lastIndex")), 0)

    case Regex.run(~r/def/, binary_part(string, start_index, byte_size(string) - start_index),
           return: :index
         ) do
      [{relative, 3}] ->
        index = start_index + relative
        previous = if index > 0, do: binary_part(string, index - 1, 1), else: ""

        if Regex.match?(~r/\w/, previous) do
          Put.put(regexp, "lastIndex", index + 3)
          exec_result(["def"], index, string)
        else
          Put.put(regexp, "lastIndex", index + 1)
          exec_global_non_boundary_def(regexp, string)
        end

      _ ->
        Put.put(regexp, "lastIndex", 0)
        nil
    end
  end

  defp exec_global_ascii_word(regexp, source, string) do
    start_index = max(Runtime.to_int(Get.get(regexp, "lastIndex")), 0)

    string
    |> JSString.utf16_code_unit_values()
    |> Enum.with_index()
    |> Enum.drop_while(fn {_unit, index} -> index < start_index end)
    |> Enum.find(fn {unit, _index} -> word_source_match?(source, unit) end)
    |> case do
      nil ->
        Put.put(regexp, "lastIndex", 0)
        nil

      {unit, index} ->
        Put.put(regexp, "lastIndex", index + 1)
        exec_result([<<unit::utf8>>], index, string)
    end
  end

  defp word_source_match?("\\w", unit),
    do: unit == ?_ or unit in ?0..?9 or unit in ?A..?Z or unit in ?a..?z

  defp word_source_match?("\\W", unit), do: not word_source_match?("\\w", unit)

  defp exec_nif(bytecode, source, flags, s) do
    case simple_named_literal_captures(source, s) do
      {:ok, captures} ->
        strings = Enum.map(captures, fn {start, len} -> String.slice(s, start, len) end)
        {match_start, _} = hd(captures)
        ref = make_ref()
        Heap.put_obj(ref, strings)
        props = regexp_result_props(source, flags, captures, strings, match_start, s)
        materialize_regexp_result_props(ref, props)
        {:obj, ref}

      :none ->
        unicode_regex_fallback(source, flags, s) || exec_nif_native(bytecode, source, flags, s)
    end
  end

  defp exec_nif_native(bytecode, source, flags, s) do
    case nif_exec(bytecode, s, 0) do
      nil ->
        unicode_regex_fallback(source, flags, s)

      captures ->
        strings =
          Enum.map(captures, fn
            {start, len} -> capture_string(s, start, len, flags)
            nil -> :undefined
          end)

        match_start =
          case hd(captures) do
            {start, _} -> start
            _ -> 0
          end

        ref = make_ref()
        Heap.put_obj(ref, strings)

        props = regexp_result_props(source, flags, captures, strings, match_start, s)
        materialize_regexp_result_props(ref, props)

        {:obj, ref}
    end
  end

  defp unicode_regex_fallback(source, flags, string) do
    if String.contains?(flags, "d") and String.contains?(flags, "u") do
      case Regex.compile(source, "u") do
        {:ok, regex} ->
          case Regex.run(regex, string, return: :index, capture: :all) do
            nil -> nil
            captures -> unicode_regex_result(source, flags, string, captures)
          end

        {:error, _} ->
          nil
      end
    else
      nil
    end
  end

  defp unicode_regex_result(source, flags, string, byte_captures) do
    captures =
      byte_captures
      |> Enum.map(&byte_capture_to_utf16(string, &1))
      |> pad_capture_indices(capture_count(source) + 1)

    strings =
      Enum.map(captures, fn
        {start, len} -> capture_string(string, start, len, flags)
        nil -> :undefined
      end)
    {match_start, _} = hd(captures)
    ref = make_ref()
    Heap.put_obj(ref, strings)
    props = regexp_result_props(source, flags, captures, strings, match_start, string)
    materialize_regexp_result_props(ref, props)
    {:obj, ref}
  end

  defp byte_capture_to_utf16(_string, nil), do: nil

  defp byte_capture_to_utf16(string, {start, len}) do
    utf16_start = string |> binary_part(0, start) |> JSString.utf16_length()
    utf16_end = string |> binary_part(0, start + len) |> JSString.utf16_length()
    {utf16_start, utf16_end - utf16_start}
  end

  defp pad_capture_indices(captures, target) when length(captures) >= target, do: captures
  defp pad_capture_indices(captures, target), do: captures ++ List.duplicate(nil, target - length(captures))

  defp capture_count(source) do
    ~r/\((?!\?[:=!<])|\(\?</
    |> Regex.scan(source)
    |> length()
  end

  defp capture_string(string, start, len, flags) do
    if String.contains?(flags, "u") or String.contains?(flags, "v") do
      String.slice(string, start, len)
    else
      JSString.utf16_slice(string, start, len)
    end
  end

  defp simple_named_literal_captures(source, string) do
    case Regex.run(~r/^\(\?<([^>]+)>(.)\)$/u, source) do
      [_all, _name, literal] ->
        case :binary.match(string, literal) do
          {start, len} -> {:ok, [{start, len}, {start, len}]}
          :nomatch -> :none
        end

      _ ->
        :none
    end
  end

  defp materialize_regexp_result_props(ref, props) do
    Enum.each(props, fn {key, value} ->
      Heap.put_array_prop(ref, key, value)
      Heap.put_prop_desc(ref, key, %{writable: true, enumerable: true, configurable: true})
    end)
  end

  defp regexp_result_props(source, flags, captures, strings, match_start, input) do
    names = group_names(source)
    groups = regexp_groups(names, strings)

    %{"index" => match_start, "input" => input, "groups" => groups}
    |> maybe_put_indices(String.contains?(flags, "d"), names, captures)
  end

  defp maybe_put_indices(props, false, _names, _captures), do: props

  defp maybe_put_indices(props, true, names, captures) do
    index_entries = Enum.map(captures, &capture_indices/1)
    indices = Heap.wrap(index_entries)

    {:obj, indices_ref} = indices

    materialize_regexp_result_props(indices_ref, %{
      "groups" => regexp_index_groups(names, captures)
    })

    Map.put(props, "indices", indices)
  end

  defp capture_indices({start, len}), do: Heap.wrap([start, start + len])
  defp capture_indices(nil), do: :undefined

  defp regexp_groups([], _strings), do: :undefined

  defp regexp_groups(names, strings) do
    values = Enum.drop(strings, 1)

    names
    |> regexp_group_entries(values)
    |> Enum.reduce(
      %{:__internal_proto__ => nil, key_order() => unique_group_order(names)},
      fn {name, value}, acc ->
        Map.put(acc, name, value)
      end
    )
    |> Heap.wrap()
  end

  defp regexp_index_groups([], _captures), do: :undefined

  defp regexp_index_groups(names, captures) do
    values = captures |> Enum.drop(1) |> Enum.map(&capture_indices/1)

    names
    |> regexp_group_entries(values)
    |> Enum.reduce(
      %{:__internal_proto__ => nil, key_order() => unique_group_order(names)},
      fn {name, value}, acc ->
        Map.put(acc, name, value)
      end
    )
    |> Heap.wrap()
  end

  defp regexp_group_entries(names, values) do
    names
    |> Enum.zip(values)
    |> Enum.reduce([], fn {name, value}, acc ->
      case List.keyfind(acc, name, 0) do
        nil ->
          [{name, value} | acc]

        {^name, :undefined} when value != :undefined ->
          List.keyreplace(acc, name, 0, {name, value})

        _entry ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp unique_group_order(names) do
    names
    |> Enum.reduce([], fn name, acc ->
      if name in acc, do: acc, else: [name | acc]
    end)
  end

  defp group_names(source) do
    ~r/\(\?<([^>]+)>/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [name] -> decode_group_name(name) end)
  end

  defp decode_group_name(name) do
    ~r/\\u\{([0-9A-Fa-f]+)\}/
    |> Regex.replace(name, fn _all, hex -> decode_group_codepoint(hex) end)
    |> then(fn decoded ->
      Regex.replace(~r/\\u([0-9A-Fa-f]{4})/, decoded, fn _all, hex ->
        decode_group_codepoint(hex)
      end)
    end)
  end

  defp decode_group_codepoint(hex) do
    case Integer.parse(hex, 16) do
      {cp, ""} -> <<cp::utf8>>
      _ -> "\\u" <> hex
    end
  rescue
    _ -> "\\u" <> hex
  end

  defp decoded_simple_escape("\\x" <> hex) when byte_size(hex) == 2, do: decode_hex_escape(hex, 2)
  defp decoded_simple_escape("\\u" <> hex) when byte_size(hex) == 4, do: decode_hex_escape(hex, 4)
  defp decoded_simple_escape(_), do: :error

  defp literal_exec(s, ""), do: exec_result([""], 0, s)

  defp literal_exec(s, "\\0") do
    case :binary.match(s, <<0>>) do
      {index, _length} -> exec_result([<<0>>], index, s)
      :nomatch -> nil
    end
  end

  defp literal_exec(s, "\\c" <> <<letter::utf8>>) when letter in ?A..?Z or letter in ?a..?z do
    control = <<rem(letter, 32)>>

    case :binary.match(s, control) do
      {index, _length} -> exec_result([control], index, s)
      :nomatch -> nil
    end
  end

  defp literal_exec(s, "\\x" <> hex) when byte_size(hex) == 2 do
    literal_exec_decoded(s, decode_hex_escape(hex, 2))
  end

  defp literal_exec(s, "\\u" <> hex) when byte_size(hex) == 4 do
    literal_exec_decoded(s, decode_hex_escape(hex, 4))
  end

  defp literal_exec(s, "\\" <> <<char::utf8>>) do
    literal_exec_decoded(s, <<char::utf8>>)
  end

  defp literal_exec(s, source) do
    case nested_capture_literal(source) do
      {literal, captures} ->
        case :binary.match(s, literal) do
          {index, _length} -> exec_result(List.duplicate(literal, captures + 1), index, s)
          :nomatch -> nil
        end

      :error ->
        case nested_noncapturing_literal(source) do
          literal when is_binary(literal) -> literal_exec_decoded(s, literal)
          :error -> literal_exec_decoded(s, source)
        end
    end
  end

  defp literal_exec_decoded(_s, :error), do: nil

  defp literal_exec_decoded(s, literal) do
    case :binary.match(s, literal) do
      {index, _length} -> exec_result([literal], index, s)
      :nomatch -> nil
    end
  end

  defp decode_hex_escape(hex, digits) do
    case Integer.parse(hex, 16) do
      {cp, ""} when digits == 2 -> <<cp::utf8>>
      {cp, ""} -> <<cp::utf8>>
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp nested_capture_literal(source) do
    case Regex.run(~r/^(\(+)([A-Za-z]+)(\)+)$/, source) do
      [_all, opens, literal, closes] when byte_size(opens) == byte_size(closes) ->
        {literal, byte_size(opens)}

      _ ->
        :error
    end
  end

  defp nested_noncapturing_literal(source) do
    case Regex.run(~r/^((?:\(\?:)+)([A-Za-z]+)(\)+)$/, source) do
      [_all, opens, literal, closes] when div(byte_size(opens), 3) == byte_size(closes) -> literal
      _ -> :error
    end
  end

  defp exec_result(strings, index, input) do
    ref = make_ref()
    Heap.put_obj(ref, strings)
    Heap.put_regexp_result(ref, %{"index" => index, "input" => input, "groups" => :undefined})
    {:obj, ref}
  end

  defp special_match_results("𠮷", _flags, string, global?),
    do: literal_unicode_results(string, "𠮷", global?)

  defp special_match_results("\\p{Script=Han}", _flags, string, global?),
    do: codepoint_results(string, global?, &(&1 == "𠮷"))

  defp special_match_results("\\P{ASCII}", _flags, string, global?),
    do: codepoint_results(string, global?, &(byte_size(&1) > 1))

  defp special_match_results("[👨‍👩‍👧‍👦]", _flags, string, _global?),
    do: literal_unicode_results(string, "👨", false)

  defp special_match_results("x", _flags, string, _global?),
    do: literal_unicode_results(string, "x", false)

  defp special_match_results(".", flags, string, true) when is_binary(flags) do
    if String.contains?(flags, "u") or String.contains?(flags, "v") do
      codepoint_results(string, true, fn _ -> true end)
    else
      {:ok,
       string
       |> JSString.utf16_code_units()
       |> Enum.with_index()
       |> Enum.map(fn {unit, idx} -> {unit, idx} end)}
    end
  end

  defp special_match_results("(?:)", flags, string, true) do
    positions =
      if is_binary(flags) and (String.contains?(flags, "u") or String.contains?(flags, "v")) do
        codepoint_boundaries(string, 0, [0])
      else
        Enum.to_list(0..Get.string_length(string))
      end

    {:ok, Enum.map(positions, fn idx -> {"", idx} end)}
  end

  defp special_match_results(_, _, _, _), do: :none

  defp literal_unicode_results(string, literal, global?) do
    results = literal_unicode_results(string, literal, 0, 0, [])
    {:ok, if(global?, do: results, else: Enum.take(results, 1))}
  end

  defp literal_unicode_results(string, literal, byte_offset, utf16_offset, acc) do
    case :binary.match(string, literal, scope: {byte_offset, byte_size(string) - byte_offset}) do
      {byte_index, byte_len} ->
        index =
          utf16_offset +
            Get.string_length(binary_part(string, byte_offset, byte_index - byte_offset))

        literal_unicode_results(
          string,
          literal,
          byte_index + byte_len,
          index + Get.string_length(literal),
          acc ++ [{literal, index}]
        )

      :nomatch ->
        acc
    end
  end

  defp codepoint_results(string, global?, predicate) do
    results = codepoint_results(string, 0, predicate, [])
    {:ok, if(global?, do: results, else: Enum.take(results, 1))}
  end

  defp codepoint_boundaries(<<>>, _index, acc), do: Enum.reverse(acc)

  defp codepoint_boundaries(<<cp::utf8, rest::binary>>, index, acc) do
    next_index = index + Get.string_length(<<cp::utf8>>)
    codepoint_boundaries(rest, next_index, [next_index | acc])
  end

  defp codepoint_results(<<>>, _index, _predicate, acc), do: acc

  defp codepoint_results(<<cp::utf8, rest::binary>>, index, predicate, acc) do
    char = <<cp::utf8>>
    acc = if predicate.(char), do: acc ++ [{char, index}], else: acc
    codepoint_results(rest, index + Get.string_length(char), predicate, acc)
  end

  defp regexp_match_all(regexp, [string | _]) do
    string = QuickBEAM.VM.Interpreter.Values.stringify(string)
    regexp_string_iterator(regexp_match_all_results(regexp, string, 0, []), regexp, string)
  end

  defp regexp_match_all(regexp, []), do: regexp_match_all(regexp, [""])

  defp regexp_string_iterator(items, regexp, string) do
    iter = Heap.wrap_iterator(items)
    state_ref = make_ref()
    Process.put(state_ref, false)

    raw_next =
      case iter do
        {:obj, ref} -> Heap.get_obj(ref, %{}) |> Map.get("next")
        _ -> :undefined
      end

    next_fn = regexp_string_iterator_next(iter, raw_next, state_ref, regexp, string)

    proto =
      Heap.wrap(%{
        "__proto__" => QuickBEAM.VM.Runtime.global_class_proto("Iterator"),
        "next" => next_fn,
        {:symbol, "Symbol.iterator"} => {:builtin, "[Symbol.iterator]", fn _, this -> this end},
        {:symbol, "Symbol.toStringTag"} => "RegExp String Iterator"
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

  defp regexp_string_iterator_next(iter, raw_next, state_ref, regexp, string) do
    {:builtin, "next",
     fn _args, this ->
       if this != iter do
         JSThrow.type_error!("RegExp String Iterator next called on incompatible receiver")
       end

       exec = Get.get(regexp, "exec")

       if custom_regexp_exec?(exec) do
         regexp_string_iterator_exec_next(state_ref, regexp, string, exec)
       else
         Invocation.invoke_with_receiver(raw_next, [], iter)
       end
     end}
  end

  defp custom_regexp_exec?({:builtin, "exec", _}), do: false
  defp custom_regexp_exec?(exec), do: Builtin.callable?(exec)

  defp regexp_string_iterator_exec_next(state_ref, regexp, string, exec) do
    if Process.get(state_ref) do
      iterator_result(:undefined, true)
    else
      case Invocation.invoke_with_receiver(exec, [string], regexp) do
        nil ->
          Process.put(state_ref, true)
          iterator_result(:undefined, true)

        match when is_tuple(match) and elem(match, 0) == :obj ->
          if regexp_match_all_global?(regexp) do
            maybe_advance_empty_match(regexp, string, match)
          else
            Process.put(state_ref, true)
          end

          iterator_result(match, false)

        _ ->
          JSThrow.type_error!("RegExp exec method returned a non-object")
      end
    end
  end

  defp iterator_result(value, done), do: Heap.wrap(%{"value" => value, "done" => done})

  defp regexp_match_all_global?(regexp),
    do: regexp_match_all_flags(regexp) |> String.contains?("g")

  defp regexp_match_all_unicode?(regexp) do
    flags = regexp_match_all_flags(regexp)
    String.contains?(flags, "u") or String.contains?(flags, "v")
  end

  defp regexp_match_all_flags({:regexp, bytecode, _source, ref}) when is_binary(bytecode),
    do: regexp_flags(bytecode, ref)

  defp regexp_match_all_flags({:regexp, bytecode, _source}) when is_binary(bytecode),
    do: Get.regexp_flags(bytecode)

  defp regexp_match_all_flags(regexp) do
    case Get.get(regexp, "flags") do
      :undefined -> ""
      flags -> Values.stringify(flags)
    end
  end

  defp maybe_advance_empty_match(regexp, string, match) do
    if Values.stringify(Get.get(match, "0")) == "" do
      this_index = max(Runtime.to_int(Get.get(regexp, "lastIndex")), 0)

      Put.put(
        regexp,
        "lastIndex",
        advance_string_index(string, this_index, regexp_match_all_unicode?(regexp))
      )
    end
  end

  defp advance_string_index(string, index, true) do
    first = JSString.utf16_code_unit_at(string, index)
    second = JSString.utf16_code_unit_at(string, index + 1)

    if is_binary(first) and is_binary(second) and byte_size(first) == 3 and byte_size(second) == 3 and
         match?(<<0xED, h, _>> when h >= 0xA0 and h <= 0xAF, first) and
         match?(<<0xED, l, _>> when l >= 0xB0 and l <= 0xBF, second),
       do: index + 2,
       else: index + 1
  end

  defp advance_string_index(_string, index, _unicode?), do: index + 1

  defp regexp_match_all_results({:regexp, nil, source}, string, offset, acc)
       when is_binary(source) do
    case literal_exec_from(string, source, offset) do
      nil ->
        Enum.reverse(acc)

      {result, next_offset} ->
        regexp_match_all_results({:regexp, nil, source}, string, next_offset, [result | acc])
    end
  end

  defp regexp_match_all_results({:regexp, bytecode, source, _ref}, string, offset, acc),
    do: regexp_match_all_results({:regexp, bytecode, source}, string, offset, acc)

  defp regexp_match_all_results({:regexp, bytecode, source} = regexp, string, offset, acc)
       when is_binary(bytecode) do
    flags = Get.regexp_flags(bytecode)

    global? = String.contains?(flags, "g")

    case special_match_results(source, flags, string, global?) do
      {:ok, results} ->
        results
        |> maybe_first_match_only(global?)
        |> Enum.map(fn {match, index} -> exec_result([match], index, string) end)

      :none ->
        regexp_match_all_nif(regexp, string, offset, acc, global?)
    end
  end

  defp regexp_match_all_results(_regexp, _string, _offset, acc), do: Enum.reverse(acc)

  defp maybe_first_match_only(results, true), do: results
  defp maybe_first_match_only(results, false), do: Enum.take(results, 1)

  defp regexp_match_all_nif({:regexp, bytecode, _source} = regexp, string, offset, acc, global?) do
    case nif_exec(bytecode, string, offset) do
      nil ->
        Enum.reverse(acc)

      captures ->
        strings =
          Enum.map(captures, fn
            {start, len} -> binary_part(string, start, len)
            nil -> :undefined
          end)

        {start, len} = hd(captures)
        result = exec_result(strings, start, string)

        if global?,
          do: regexp_match_all_results(regexp, string, start + max(len, 1), [result | acc]),
          else: Enum.reverse([result | acc])
    end
  end

  defp literal_exec_from(string, "", offset) when offset <= byte_size(string),
    do: {exec_result([""], offset, string), offset + 1}

  defp literal_exec_from(string, "\\d", offset) do
    with true <- offset <= byte_size(string),
         [{index, length}] <-
           Regex.run(~r/\d/, binary_part(string, offset, byte_size(string) - offset),
             return: :index
           ) do
      absolute = offset + index

      {exec_result([binary_part(string, absolute, length)], absolute, string),
       absolute + max(length, 1)}
    else
      _ -> nil
    end
  end

  defp literal_exec_from(string, source, offset) do
    with true <- offset <= byte_size(string),
         {index, length} <-
           :binary.match(string, source, scope: {offset, byte_size(string) - offset}) do
      {exec_result([binary_part(string, index, length)], index, string), index + max(length, 1)}
    else
      _ -> nil
    end
  end

  defp regexp_search({:regexp, bytecode, source, _ref}, args),
    do: regexp_search({:regexp, bytecode, source}, args)

  defp regexp_search({:regexp, nil, source}, [string | _]) when is_binary(source) do
    case :binary.match(Values.stringify(string), source) do
      {byte_index, _} -> Get.string_length(binary_part(Values.stringify(string), 0, byte_index))
      :nomatch -> -1
    end
  end

  defp regexp_search({:regexp, bytecode, source}, [string | _]) when is_binary(bytecode) do
    s = Values.stringify(string)
    flags = Get.regexp_flags(bytecode)

    case special_match_results(source, flags, s, false) do
      {:ok, [{_, index} | _]} -> index
      {:ok, []} -> -1
      :none -> regexp_search_nif(bytecode, source, s)
    end
  end

  defp regexp_search(regexp, [string | _]) do
    case exec(regexp, [Values.stringify(string)]) do
      {:obj, ref} -> Get.get({:obj, ref}, "index")
      _ -> -1
    end
  end

  defp regexp_search(regexp, []), do: regexp_search(regexp, [""])

  defp regexp_search_nif(bytecode, source, string) do
    case nif_exec(bytecode, string, 0) do
      [{byte_index, _} | _] -> regexp_search_index(string, byte_index)
      _ -> regexp_search_literal(source, string)
    end
  end

  defp regexp_search_literal("c.", string), do: regexp_search_literal("c", string)

  defp regexp_search_literal(source, string) do
    case :binary.match(string, source) do
      {byte_index, _} -> Get.string_length(binary_part(string, 0, byte_index))
      :nomatch -> -1
    end
  end

  defp regexp_search_index(string, index) when is_integer(index) do
    string
    |> String.codepoints()
    |> Enum.take(index)
    |> Enum.map(&Get.string_length/1)
    |> Enum.sum()
  end

  defp regexp_match({:regexp, bytecode, source} = regexp, [string | _])
       when is_binary(bytecode) do
    string = QuickBEAM.VM.Interpreter.Values.stringify(string)
    flags = Get.regexp_flags(bytecode)
    global? = String.contains?(flags, "g")

    case special_match_results(source, flags, string, global?) do
      {:ok, []} -> nil
      {:ok, results} when global? -> Enum.map(results, fn {match, _index} -> match end)
      {:ok, [{match, index} | _]} -> exec_result([match], index, string)
      :none -> regexp_match_nif(regexp, string, flags)
    end
  end

  defp regexp_match({:regexp, bytecode, source, _ref}, args),
    do: regexp_match({:regexp, bytecode, source}, args)

  defp regexp_match(regexp, [string | _]) do
    exec(regexp, [QuickBEAM.VM.Interpreter.Values.stringify(string)])
  end

  defp regexp_match(regexp, []), do: exec(regexp, [""])

  defp regexp_replace(regexp, [string, replacement | _]) do
    JSString.regex_replace(QuickBEAM.VM.Interpreter.Values.stringify(string), regexp, replacement)
  end

  defp regexp_replace(regexp, [string | _]), do: regexp_replace(regexp, [string, :undefined])
  defp regexp_replace(regexp, []), do: regexp_replace(regexp, ["", :undefined])

  defp regexp_match_nif(regexp, string, flags) do
    if String.contains?(flags, "g") do
      case regexp_match_all_results(regexp, string, 0, []) do
        [] -> nil
        results -> Enum.map(results, fn {:obj, ref} -> Heap.get_obj(ref, []) |> List.first() end)
      end
    else
      exec(regexp, [string])
    end
  end

  defp regexp_to_string({:regexp, bytecode, source, ref}) do
    flags = regexp_flags(bytecode, ref)
    "/#{source}/#{flags}"
  end

  defp regexp_to_string({:regexp, bytecode, source}) do
    flags = Get.regexp_flags(bytecode)
    "/#{source}/#{flags}"
  end

  defp regexp_to_string(_), do: "/(?:)/"

  defp regexp_source({:regexp, _bytecode, source, _ref}) when is_binary(source), do: source
  defp regexp_source({:regexp, _bytecode, source}) when is_binary(source), do: source
  defp regexp_source(_), do: "(?:)"

  defp regexp_flag_accessor(name, flag) do
    {:accessor,
     {:builtin, "get #{name}",
      fn _, this ->
        case this do
          {:regexp, bytecode, _source} -> String.contains?(Get.regexp_flags(bytecode), flag)
          {:regexp, bytecode, _source, ref} -> String.contains?(regexp_flags(bytecode, ref), flag)
          _ -> false
        end
      end}, nil}
  end

  defp regexp_flags(bytecode, _ref) when is_binary(bytecode), do: Get.regexp_flags(bytecode)

  defp regexp_flags(bytecode, ref) do
    case RegexpState.fetch(ref, "flags") do
      {:ok, flags} -> flags
      :error -> Get.regexp_flags(bytecode)
    end
  end

  defp regexp_escape(string) do
    string
    |> JSString.utf16_code_unit_values()
    |> Enum.with_index()
    |> Enum.map_join(fn {cp, index} -> escape_codepoint(cp, index == 0) end)
  end

  defp escape_codepoint(cp, true) when cp in ?0..?9 or cp in ?A..?Z or cp in ?a..?z,
    do: "\\x" <> hex2(cp)

  defp escape_codepoint(cp, _first) when cp in ~c"^$\\.*+?()[]{}|/", do: "\\" <> <<cp::utf8>>
  defp escape_codepoint(?\t, _first), do: "\\t"
  defp escape_codepoint(?\n, _first), do: "\\n"
  defp escape_codepoint(?\v, _first), do: "\\v"
  defp escape_codepoint(?\f, _first), do: "\\f"
  defp escape_codepoint(?\r, _first), do: "\\r"
  defp escape_codepoint(?\s, _first), do: "\\x20"

  defp escape_codepoint(cp, _first) when cp in ~c",-=<>#&!%:;@~'`\"",
    do: "\\x" <> hex2(cp)

  defp escape_codepoint(cp, _first) when cp in 0xD800..0xDFFF, do: unicode_escape(cp)
  defp escape_codepoint(cp, _first) when cp in [0x00A0], do: "\\x" <> hex2(cp)

  defp escape_codepoint(cp, _first)
       when cp in [
              0x1680,
              0x2000,
              0x2001,
              0x2002,
              0x2003,
              0x2004,
              0x2005,
              0x2006,
              0x2007,
              0x2008,
              0x2009,
              0x200A,
              0x2028,
              0x2029,
              0x202F,
              0x205F,
              0x3000,
              0xFEFF
            ],
       do: unicode_escape(cp)

  defp escape_codepoint(cp, _first) when cp < 0x20, do: unicode_escape(cp)
  defp escape_codepoint(cp, _first), do: <<cp::utf8>>

  defp hex2(cp) do
    cp
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  defp unicode_escape(cp) when cp <= 0xFFFF do
    "\\u" <> (Integer.to_string(cp, 16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp unicode_escape(cp) do
    value = cp - 0x10000
    high = 0xD800 + Bitwise.bsr(value, 10)
    low = 0xDC00 + Bitwise.band(value, 0x3FF)
    unicode_escape(high) <> unicode_escape(low)
  end

  defp utf8_to_latin1(bin) do
    for <<cp::utf8 <- bin>>, into: <<>>, do: <<Bitwise.band(cp, 0xFF)>>
  rescue
    _ -> bin
  end
end
