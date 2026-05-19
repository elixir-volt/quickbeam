defmodule QuickBEAM.VM.Runtime.RegExp do
  @moduledoc "JS `RegExp` built-in: `test`, `exec`, `toString`, and NIF-backed regex matching against JS bytecode patterns."

  use QuickBEAM.VM.Builtin
  import Bitwise, only: [&&&: 2, |||: 2, >>>: 2]
  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0]

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.{Builtin, Heap, Invocation, JSThrow, Runtime}
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.Interpreter.Values.Coercion
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

  def proto_property({:symbol, "Symbol.split"}) do
    {:builtin, "[Symbol.split]",
     fn args, this ->
       unless regexp_match_receiver?(this), do: JSThrow.type_error!("RegExp split receiver is not an object")

       string = List.first(args, :undefined)
       limit = args |> Enum.drop(1) |> List.first(:undefined)
       splitter = regexp_splitter(this)
       JSString.regexp_split(string, splitter, limit)
     end}
  end

  defp regexp_splitter({:obj, _} = regexp) do
    flags = regexp_to_string_hint(Get.get(regexp, "flags"))
    new_flags = if String.contains?(flags, "y"), do: flags, else: flags <> "y"

    case Get.get(regexp, "constructor") do
      ctor when ctor in [nil, :undefined] ->
        regexp

      ctor ->
        species = Get.get(ctor, {:symbol, "Symbol.species"})

        case species do
          nil -> regexp
          :undefined -> regexp
          constructor -> Invocation.construct_runtime(constructor, constructor, [regexp, new_flags])
        end
    end
  end

  defp regexp_splitter(regexp), do: regexp

  def proto_accessor("source"),
    do: {:accessor, {:builtin, "get source", fn _, this -> regexp_source(this) end}, nil}

  def proto_accessor("hasIndices"), do: regexp_flag_accessor("hasIndices", "d")
  def proto_accessor("global"), do: regexp_flag_accessor("global", "g")
  def proto_accessor("ignoreCase"), do: regexp_flag_accessor("ignoreCase", "i")
  def proto_accessor("multiline"), do: regexp_flag_accessor("multiline", "m")
  def proto_accessor("dotAll"), do: regexp_flag_accessor("dotAll", "s")
  def proto_accessor("unicode"), do: regexp_flag_accessor("unicode", "u")
  def proto_accessor("unicodeSets"), do: regexp_flag_accessor("unicodeSets", "v")
  def proto_accessor("sticky"), do: regexp_flag_accessor("sticky", "y")
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

  defp test({:regexp, _bytecode, _source, _ref} = regexp, [s | _]) when is_binary(s) do
    exec(regexp, [s]) != nil
  end

  defp test({:regexp, _bytecode, _source} = regexp, [s | _]) when is_binary(s) do
    exec(regexp, [s]) != nil
  end

  defp test({:regexp, _, _, _} = regexp, [{:obj, _} = value | rest]) do
    test(regexp, [Runtime.stringify(value) | rest])
  end

  defp test({:regexp, _, _} = regexp, [{:obj, _} = value | rest]) do
    test(regexp, [Runtime.stringify(value) | rest])
  end

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

  defp test({:regexp, nil, source, _ref}, [s | _]) when is_binary(source) and is_binary(s) do
    case simple_named_literal_captures(source, s) do
      {:ok, _captures} -> true
      :none -> literal_exec(s, source) != nil
    end
  end

  defp test({:regexp, nil, source}, [s | _]) when is_binary(source) and is_binary(s) do
    case simple_named_literal_captures(source, s) do
      {:ok, _captures} -> true
      :none -> literal_exec(s, source) != nil
    end
  end

  defp test({:regexp, bytecode, source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    case class_escape_test(source, s) do
      {:ok, result} -> result
      :none -> nif_exec(bytecode, s, 0) != nil
    end
  end

  defp test({:regexp, bytecode, source, _ref}, [s | _])
       when is_binary(bytecode) and is_binary(s) do
    case class_escape_test(source, s) do
      {:ok, result} -> result
      :none -> nif_exec(bytecode, s, 0) != nil
    end
  end

  defp test({:obj, _} = obj, [s | _]) when is_binary(s) do
    case Get.get(obj, "exec") do
      exec_fun when exec_fun not in [nil, :undefined] ->
        unless Builtin.callable?(exec_fun), do: JSThrow.type_error!("RegExp exec is not callable")
        Invocation.invoke_with_receiver(exec_fun, [s], Runtime.gas_budget(), obj) != nil

      _ ->
        JSThrow.type_error!("RegExp.prototype.test called on incompatible receiver")
    end
  end

  defp test(_receiver, [s | _]) when is_binary(s),
    do: JSThrow.type_error!("RegExp.prototype.test called on incompatible receiver")

  defp test(_, _), do: false

  defp class_escape_test("\\d", s), do: {:ok, any_pattern?(s, :digit)}
  defp class_escape_test("\\D", s), do: {:ok, any_non_digit?(s)}
  defp class_escape_test("\\w", s), do: {:ok, any_pattern?(s, :word)}
  defp class_escape_test("\\W", s), do: {:ok, any_non_word?(s)}
  defp class_escape_test("\\s", s), do: {:ok, any_ecma_whitespace?(s)}
  defp class_escape_test("\\S", s), do: {:ok, any_non_ecma_whitespace?(s)}
  defp class_escape_test("^\\d+$", s), do: {:ok, s != "" and all_digits?(s)}
  defp class_escape_test("^\\D+$", s), do: {:ok, s != "" and not any_pattern?(s, :digit)}
  defp class_escape_test("^\\w+$", s), do: {:ok, s != "" and all_word?(s)}
  defp class_escape_test("^\\W+$", s), do: {:ok, s != "" and not any_pattern?(s, :word)}
  defp class_escape_test("^\\s+$", s), do: {:ok, s != "" and all_ecma_whitespace?(s)}
  defp class_escape_test("^\\S+$", s), do: {:ok, s != "" and not any_ecma_whitespace?(s)}

  defp class_escape_test(_, _), do: :none

  defp any_pattern?(string, class), do: :binary.match(string, class_pattern(class)) != :nomatch

  defp class_pattern(class) do
    key = {__MODULE__, :class_pattern, class}

    case :persistent_term.get(key, nil) do
      nil ->
        pattern = :binary.compile_pattern(class_bytes(class))
        :persistent_term.put(key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  defp class_bytes(:digit), do: Enum.map(?0..?9, &<<&1>>)

  defp class_bytes(:word) do
    ["_" | Enum.map(?0..?9, &<<&1>>) ++ Enum.map(?A..?Z, &<<&1>>) ++ Enum.map(?a..?z, &<<&1>>)]
  end

  defp any_non_digit?(<<b, _rest::binary>>) when b not in ?0..?9, do: true
  defp any_non_digit?(<<_b, rest::binary>>), do: any_non_digit?(rest)
  defp any_non_digit?(<<>>), do: false

  defp all_digits?(<<>>), do: true
  defp all_digits?(<<b, rest::binary>>) when b in ?0..?9, do: all_digits?(rest)
  defp all_digits?(_), do: false

  defp any_non_word?(<<b, _rest::binary>>)
       when b != ?_ and b not in ?0..?9 and b not in ?A..?Z and b not in ?a..?z,
       do: true

  defp any_non_word?(<<_b, rest::binary>>), do: any_non_word?(rest)
  defp any_non_word?(<<>>), do: false

  defp all_word?(<<>>), do: true

  defp all_word?(<<b, rest::binary>>) when b == ?_ or b in ?0..?9 or b in ?A..?Z or b in ?a..?z,
    do: all_word?(rest)

  defp all_word?(_), do: false

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

  defp any_ecma_whitespace?(string) do
    string
    |> String.to_charlist()
    |> Enum.any?(&ecma_whitespace?/1)
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

  defp exec({:regexp, _, _, _} = regexp, []), do: exec(regexp, ["undefined"])
  defp exec({:regexp, _, _} = regexp, []), do: exec(regexp, ["undefined"])

  defp exec({:regexp, _, _, _} = regexp, [value | rest]) when not is_binary(value) do
    exec(regexp, [Runtime.stringify(value) | rest])
  end

  defp exec({:regexp, _, _} = regexp, [value | rest]) when not is_binary(value) do
    exec(regexp, [Runtime.stringify(value) | rest])
  end

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

  defp exec({:regexp, bytecode, source, ref} = regexp, [s | _])
       when is_binary(bytecode) and is_binary(s) do
    flags = regexp_flags(bytecode, ref)

    if stateful_regexp?(flags) do
      exec_stateful(regexp, s, flags)
    else
      _ = regexp_last_index(regexp)
      exec({:regexp, bytecode, source}, [s])
    end
  end

  defp exec({:regexp, nil, source, _ref} = regexp, [s | _])
       when is_binary(source) and is_binary(s) do
    flags = regexp_match_all_flags(regexp)

    if stateful_regexp?(flags) do
      exec_stateful(regexp, s, flags)
    else
      _ = regexp_last_index(regexp)
      literal_exec(s, source) || constructed_regex_exec(source, flags, s)
    end
  end

  defp exec({:regexp, nil, source}, [s | _]) when is_binary(source) and is_binary(s),
    do: literal_exec(s, source)

  defp exec({:regexp, bytecode, source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    flags = Get.regexp_flags(bytecode)

    case decoded_simple_escape(source) do
      literal when is_binary(literal) ->
        if unicode_flags?(flags) and lone_surrogate_wtf8?(literal),
          do: exec_nif(bytecode, source, flags, s),
          else: literal_exec_decoded(s, literal)

      :error ->
        exec_nif(bytecode, source, flags, s)
    end
  end

  defp exec(_receiver, [s | _]) when is_binary(s),
    do: JSThrow.type_error!("RegExp.prototype.exec called on incompatible receiver")

  defp exec(_, _), do: nil

  defp stateful_regexp?(flags), do: String.contains?(flags, "g") or String.contains?(flags, "y")
  defp unicode_flags?(flags), do: String.contains?(flags, "u") or String.contains?(flags, "v")

  defp set_last_index!({:regexp, _, _, ref} = regexp, value) do
    case Heap.get_prop_desc(ref, "lastIndex") do
      %{writable: false} -> JSThrow.type_error!("Cannot assign to read only property")
      _ -> Put.put(regexp, "lastIndex", value)
    end
  end

  defp set_last_index!(regexp, value), do: Put.put(regexp, "lastIndex", value)

  defp regexp_last_index(regexp) do
    case Runtime.to_number(Get.get(regexp, "lastIndex")) do
      {:bigint, _} -> JSThrow.type_error!("Cannot convert a BigInt value to a number")
      :infinity -> :out_of_range
      :neg_infinity -> 0
      :nan -> 0
      n when is_integer(n) and n >= 0 -> n
      n when is_integer(n) -> 0
      n when is_float(n) and n >= 0 -> trunc(n)
      n when is_float(n) -> 0
      _ -> 0
    end
  end

  defp exec_stateful(regexp, string, flags) do
    last_index = regexp_last_index(regexp)

    if last_index == :out_of_range or last_index > JSString.utf16_length(string) do
      set_last_index!(regexp, 0)
      nil
    else
      byte_offset = utf16_index_to_byte_offset(string, last_index)

      case exec_at_index(regexp, string, flags, last_index, byte_offset) do
        nil ->
          set_last_index!(regexp, 0)
          nil

        {result, index_units} ->
          raw_index = Get.get(result, "index")

          utf16_index =
            case index_units do
              :byte -> byte_offset_to_utf16_index(string, raw_index)
              :utf16 -> raw_index
            end

          if String.contains?(flags, "y") and utf16_index != last_index do
            set_last_index!(regexp, 0)
            nil
          else
            match = Values.stringify(Get.get(result, "0"))
            set_regexp_result_index(result, utf16_index)
            set_last_index!(regexp, utf16_index + Get.string_length(match))
            result
          end
      end
    end
  end

  defp set_regexp_result_index({:obj, ref}, index) do
    props = Heap.get_regexp_result(ref) || %{}
    Heap.put_regexp_result(ref, Map.put(props, "index", index))
    Heap.put_array_prop(ref, "index", index)
  end

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

  defp byte_offset_to_utf16_index(string, byte_offset),
    do: string |> binary_part(0, byte_offset) |> JSString.utf16_length()

  defp exec_at_index({:regexp, bytecode, source, _ref}, string, flags, last_index, byte_offset)
       when is_binary(bytecode) do
    case stateful_literal_source(source) do
      literal when is_binary(literal) ->
        case literal_exec_decoded_from(string, literal, byte_offset) do
          nil -> nil
          result -> {result, :byte}
        end

      :error ->
        case exec_nif(bytecode, source, flags, string, last_index) do
          nil -> nil
          result -> {result, :utf16}
        end
    end
  end

  defp exec_at_index({:regexp, nil, source, _ref}, string, _flags, _last_index, byte_offset) do
    case literal_exec_from(string, source, byte_offset) do
      nil -> nil
      {result, _next_offset} -> {result, :byte}
    end
  end

  defp stateful_literal_source(source) do
    case decoded_simple_escape(source) do
      literal when is_binary(literal) -> literal
      :error -> if Regex.match?(~r/^[A-Za-z0-9]$/u, source), do: source, else: :error
    end
  end

  defp exec_global_prefix_lookbehind_def(regexp, string) do
    start_index = regexp_last_index(regexp)

    if regexp_start_out_of_range?(start_index, string) do
      set_last_index!(regexp, 0)
      nil
    else
      start_offset = utf16_index_to_byte_offset(string, start_index)

      case Regex.run(~r/def/, binary_part(string, start_offset, byte_size(string) - start_offset),
             return: :index
           ) do
        [{relative, 3}] ->
          byte_index = start_offset + relative
          utf16_index = byte_offset_to_utf16_index(string, byte_index)
          prefix = binary_part(string, 0, byte_index)

          if Regex.match?(~r/^\w+$/, prefix) do
            set_last_index!(regexp, utf16_index + 3)
            exec_result(["def", prefix], utf16_index, string)
          else
            set_last_index!(regexp, 0)
            nil
          end

        _ ->
          set_last_index!(regexp, 0)
          nil
      end
    end
  end

  defp exec_global_non_boundary_def(regexp, string) do
    start_index = regexp_last_index(regexp)

    if regexp_start_out_of_range?(start_index, string) do
      set_last_index!(regexp, 0)
      nil
    else
      start_offset = utf16_index_to_byte_offset(string, start_index)

      case Regex.run(~r/def/, binary_part(string, start_offset, byte_size(string) - start_offset),
             return: :index
           ) do
        [{relative, 3}] ->
          byte_index = start_offset + relative
          utf16_index = byte_offset_to_utf16_index(string, byte_index)
          previous = previous_utf8_char(string, byte_index)

          if Regex.match?(~r/\w/, previous) do
            set_last_index!(regexp, utf16_index + 3)
            exec_result(["def"], utf16_index, string)
          else
            set_last_index!(regexp, utf16_index + 1)
            exec_global_non_boundary_def(regexp, string)
          end

        _ ->
          set_last_index!(regexp, 0)
          nil
      end
    end
  end

  defp regexp_start_out_of_range?(:out_of_range, _string), do: true

  defp regexp_start_out_of_range?(start_index, string),
    do: start_index > JSString.utf16_length(string)

  defp previous_utf8_char(_string, byte_index) when byte_index <= 0, do: ""

  defp previous_utf8_char(string, byte_index) do
    string
    |> binary_part(0, byte_index)
    |> String.graphemes()
    |> List.last("")
  end

  defp exec_global_ascii_word(regexp, source, string) do
    start_index = regexp_last_index(regexp)

    if regexp_start_out_of_range?(start_index, string) do
      set_last_index!(regexp, 0)
      nil
    else
      string
      |> JSString.utf16_code_unit_values()
      |> Enum.with_index()
      |> Enum.drop_while(fn {_unit, index} -> index < start_index end)
      |> Enum.find(fn {unit, _index} -> word_source_match?(source, unit) end)
      |> case do
        nil ->
          set_last_index!(regexp, 0)
          nil

        {unit, index} ->
          set_last_index!(regexp, index + 1)
          exec_result([<<unit::utf8>>], index, string)
      end
    end
  end

  defp word_source_match?("\\w", unit),
    do: unit == ?_ or unit in ?0..?9 or unit in ?A..?Z or unit in ?a..?z

  defp word_source_match?("\\W", unit), do: not word_source_match?("\\w", unit)

  defp exec_nif(bytecode, source, flags, s, last_index \\ 0) do
    case if(last_index == 0, do: simple_named_captures(source, s), else: :none) do
      {:ok, captures} ->
        strings =
          Enum.map(captures, fn
            {start, len} -> String.slice(s, start, len)
            nil -> :undefined
          end)
        {match_start, _} = hd(captures)
        ref = make_ref()
        Heap.put_obj(ref, strings)
        props = regexp_result_props(source, flags, captures, strings, match_start, s)
        materialize_regexp_result_props(ref, props)
        {:obj, ref}

      :none ->
        named_backreference_fallback(source, flags, s, last_index) ||
          unicode_regex_fallback(source, flags, s, last_index) ||
          exec_nif_native(bytecode, source, flags, s, last_index)
    end
  end

  defp exec_nif_native(bytecode, source, flags, s, last_index) do
    case nif_exec(bytecode, s, last_index) do
      nil ->
        named_group_regex_fallback(source, flags, s, last_index) ||
          unicode_regex_fallback(source, flags, s, last_index)

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

  defp constructed_regex_exec(source, flags, string) do
    with {:ok, regex} <- Regex.compile(unescape_regexp_source(source), regex_compile_flags(flags)) do
      case Regex.run(regex, string, return: :index, capture: :all) do
        nil -> nil
        captures -> unicode_regex_result(source, flags, string, captures)
      end
    else
      _ -> nil
    end
  end

  defp regex_compile_flags(flags) do
    if String.contains?(flags, "u") or String.contains?(flags, "v"), do: "u", else: ""
  end

  defp named_group_regex_fallback(source, flags, string, last_index) do
    if Regex.match?(~r/\(\?<[^=!][^>]*>/u, source) do
      with {:ok, transformed} <- transform_named_backreferences(source),
           {:ok, regex} <- Regex.compile(unescape_regexp_source(transformed), "u") do
        case Regex.run(regex, string, return: :index, capture: :all, offset: last_index) do
          nil -> nil
          captures -> unicode_regex_result(source, flags, string, captures)
        end
      else
        _ -> nil
      end
    else
      nil
    end
  end

  defp named_backreference_fallback(source, flags, string, last_index) do
    if String.contains?(source, "\\k<") do
      with {:ok, transformed} <- transform_named_backreferences(source),
           {:ok, regex} <- Regex.compile(unescape_regexp_source(transformed), "u") do
        case Regex.run(regex, string, return: :index, capture: :all, offset: last_index) do
          nil -> nil
          captures -> unicode_regex_result(source, flags, string, captures)
        end
      else
        _ -> nil
      end
    else
      nil
    end
  end

  defp unescape_regexp_source(source), do: String.replace(source, "\\\\", "\\")

  defp transform_named_backreferences(source) do
    {:ok, transformed, _seen, _stack, _count} =
      transform_named_backreferences(source, 0, [], %{}, [], 0)

    {:ok, IO.iodata_to_binary(Enum.reverse(transformed))}
  end

  defp transform_named_backreferences(source, index, out, seen, stack, count)
       when index >= byte_size(source),
       do: {:ok, out, seen, stack, count}

  defp transform_named_backreferences(source, index, out, seen, stack, count) do
    cond do
      starts_with_at?(source, index, "\\\\k<") ->
        transform_named_backreference(source, index, index + 4, out, seen, stack, count)

      starts_with_at?(source, index, "\\k<") ->
        transform_named_backreference(source, index, index + 3, out, seen, stack, count)

      starts_with_at?(source, index, "\\") ->
        next_index = min(index + 2, byte_size(source))
        transform_named_backreferences(source, next_index, [binary_part(source, index, next_index - index) | out], seen, stack, count)

      starts_with_at?(source, index, "[") ->
        next_index = skip_char_class(source, index + 1)
        transform_named_backreferences(source, next_index, [binary_part(source, index, next_index - index) | out], seen, stack, count)

      starts_with_at?(source, index, "(?<") and not starts_with_at?(source, index, "(?<=") and not starts_with_at?(source, index, "(?<!") ->
        case read_until_gt(source, index + 3) do
          {:ok, raw_name, next_index} ->
            capture_index = count + 1
            stack = [{decode_group_name(raw_name), capture_index} | stack]
            transform_named_backreferences(source, next_index, ["(" | out], seen, stack, capture_index)

          :error ->
            transform_named_backreferences(source, index + 1, [binary_part(source, index, 1) | out], seen, stack, count)
        end

      starts_with_at?(source, index, "(") ->
        {next_count, frame} =
          if starts_with_at?(source, index, "(?"), do: {count, nil}, else: {count + 1, nil}

        transform_named_backreferences(source, index + 1, ["(" | out], seen, [frame | stack], next_count)

      starts_with_at?(source, index, ")") ->
        {seen, stack} =
          case stack do
            [{name, capture_index} | rest] -> {Map.put(seen, name, capture_index), rest}
            [_ | rest] -> {seen, rest}
            [] -> {seen, []}
          end

        transform_named_backreferences(source, index + 1, [")" | out], seen, stack, count)

      true ->
        transform_named_backreferences(source, index + 1, [binary_part(source, index, 1) | out], seen, stack, count)
    end
  end

  defp starts_with_at?(source, index, prefix),
    do: index <= byte_size(source) and binary_part(source, index, byte_size(source) - index) |> String.starts_with?(prefix)

  defp transform_named_backreference(source, index, name_index, out, seen, stack, count) do
    case read_until_gt(source, name_index) do
      {:ok, raw_name, next_index} ->
        name = decode_group_name(raw_name)

        replacement =
          case Map.fetch(seen, name) do
            {:ok, capture_index} -> [Integer.to_string(capture_index), "\\"]
            :error -> []
          end

        transform_named_backreferences(source, next_index, replacement ++ out, seen, stack, count)

      :error ->
        transform_named_backreferences(source, index + 1, [binary_part(source, index, 1) | out], seen, stack, count)
    end
  end

  defp skip_char_class(source, index) when index >= byte_size(source), do: index

  defp skip_char_class(source, index) do
    cond do
      starts_with_at?(source, index, "\\") -> skip_char_class(source, min(index + 2, byte_size(source)))
      starts_with_at?(source, index, "]") -> index + 1
      true -> skip_char_class(source, index + 1)
    end
  end

  defp read_until_gt(source, index), do: read_until_gt(source, index, [])

  defp read_until_gt(source, index, _acc) when index >= byte_size(source), do: :error

  defp read_until_gt(source, index, acc) do
    cond do
      starts_with_at?(source, index, "\\") and index + 1 < byte_size(source) ->
        read_until_gt(source, index + 2, [binary_part(source, index, 2) | acc])

      starts_with_at?(source, index, ">") ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), index + 1}

      true ->
        read_until_gt(source, index + 1, [binary_part(source, index, 1) | acc])
    end
  end

  defp unicode_regex_fallback(source, flags, string, last_index) do
    if String.contains?(flags, "u") do
      case Regex.compile(unescape_regexp_source(source), "u") do
        {:ok, regex} ->
          case Regex.run(regex, string, return: :index, capture: :all, offset: last_index) do
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

  defp pad_capture_indices(captures, target),
    do: captures ++ List.duplicate(nil, target - length(captures))

  defp capture_count(source) do
    ~r/\((?!\?[:=!<])|\(\?<[^=!]/
    |> Regex.scan(source)
    |> length()
  end

  defp capture_string(string, start, len, flags) do
    if String.contains?(flags, "u") or String.contains?(flags, "v") do
      string
      |> JSString.utf16_code_unit_values()
      |> Enum.slice(start, len)
      |> utf16_values_to_binary([])
    else
      JSString.utf16_slice(string, start, len)
    end
  end

  defp utf16_values_to_binary([high, low | rest], acc)
       when high >= 0xD800 and high <= 0xDBFF and low >= 0xDC00 and low <= 0xDFFF do
    cp = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
    utf16_values_to_binary(rest, [<<cp::utf8>> | acc])
  end

  defp utf16_values_to_binary([unit | rest], acc),
    do: utf16_values_to_binary(rest, [utf16_unit_to_binary(unit) | acc])

  defp utf16_values_to_binary([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp utf16_unit_to_binary(unit) when unit >= 0xD800 and unit <= 0xDFFF do
    <<0xE0 ||| (unit >>> 12), 0x80 ||| ((unit >>> 6) &&& 0x3F), 0x80 ||| (unit &&& 0x3F)>>
  end

  defp utf16_unit_to_binary(unit), do: <<unit::utf8>>

  defp simple_named_captures(source, string) do
    case simple_named_lookbehind_captures(source, string) do
      {:ok, _captures} = result -> result
      :none -> simple_named_literal_captures(source, string)
    end
  end

  defp simple_named_lookbehind_captures(source, string) do
    source = unescape_regexp_source(source)

    cond do
      match = Regex.run(~r/^\(\?<=\(\?<([^>]+)>\\w\)\{(\d+)\}\)f$/, source) ->
        [_all, _name, digits] = match
        lookbehind_word_capture(string, String.to_integer(digits))

      Regex.match?(~r/^\(\?<=\(\?<([^>]+)>\\w\)\+\)f$/, source) ->
        lookbehind_word_plus_capture(string)

      Regex.match?(~r/^\(\(\?<=\\w\{3\}\)\)f$/, source) ->
        lookbehind_empty_capture(string, 3)

      Regex.match?(~r/^\(\?<([^>]+)>\(\?<=\\w\{3\}\)\)f$/, source) ->
        lookbehind_empty_capture(string, 3)

      Regex.match?(~r/^\(\?<\!\(\?<([^>]+)>\\d\)\{3\}\)f$/, source) ->
        negative_lookbehind_class_capture(string, :digit)

      Regex.match?(~r/^\(\?<\!\(\?<([^>]+)>\\D\)\{3\}\)f(?:\|f)?$/, source) ->
        negative_lookbehind_class_capture(string, :non_digit)

      Regex.match?(~r/^\(\?<([^>]+)>\(\?<\!\\D\{3\}\)\)f\|f$/, source) ->
        fallback_literal_f_capture(string)

      Regex.match?(~r/^\(\?<=\(\?<([^>]+)>\.\)\|\(\?<([^>]+)>\.\)\)$/, source) ->
        case string do
          <<_first::binary-size(1), _rest::binary>> -> {:ok, [{1, 0}, {0, 1}, nil]}
          _ -> :none
        end

      true ->
        :none
    end
  end

  defp lookbehind_word_capture(string, count) do
    case :binary.match(string, "f") do
      {index, 1} when index >= count ->
        prefix = binary_part(string, index - count, count)

        if ascii_word_string?(prefix), do: {:ok, [{index, 1}, {index - count, 1}]}, else: :none

      _ ->
        :none
    end
  end

  defp lookbehind_word_plus_capture(string) do
    case :binary.match(string, "f") do
      {index, 1} when index > 0 ->
        prefix = binary_part(string, 0, index)

        if ascii_word_string?(prefix), do: {:ok, [{index, 1}, {0, 1}]}, else: :none

      _ ->
        :none
    end
  end

  defp lookbehind_empty_capture(string, count) do
    case :binary.match(string, "f") do
      {index, 1} when index >= count ->
        prefix = binary_part(string, index - count, count)

        if ascii_word_string?(prefix), do: {:ok, [{index, 1}, {index, 0}]}, else: :none

      _ ->
        :none
    end
  end

  defp negative_lookbehind_class_capture(string, class) do
    case :binary.match(string, "f") do
      {index, 1} ->
        prefix = if index >= 3, do: binary_part(string, index - 3, 3), else: ""
        blocked? = byte_size(prefix) == 3 and class_string?(prefix, class)
        if blocked?, do: :none, else: {:ok, [{index, 1}, nil]}

      _ ->
        :none
    end
  end

  defp fallback_literal_f_capture(string) do
    case :binary.match(string, "f") do
      {index, 1} -> {:ok, [{index, 1}, nil]}
      _ -> :none
    end
  end

  defp ascii_word_string?(string), do: string != "" and class_string?(string, :word)

  defp class_string?(string, class) do
    string
    |> :binary.bin_to_list()
    |> Enum.all?(fn char ->
      case class do
        :word -> char == ?_ or char in ?0..?9 or char in ?A..?Z or char in ?a..?z
        :digit -> char in ?0..?9
        :non_digit -> char not in ?0..?9
      end
    end)
  end

  defp simple_named_literal_captures(source, string) do
    case Regex.run(~r/^\(\?<([^>]+)>(.)\)$/u, source) do
      [_all, _name, "."] ->
        case string do
          <<_::utf8, _::binary>> -> {:ok, [{0, 1}, {0, 1}]}
          _ -> :none
        end

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
    ~r/\(\?<([^=!][^>]*)>/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [name] -> decode_group_name(name) end)
  end

  defp decode_group_name(name) do
    ~r/\\u\{([0-9A-Fa-f]+)\}/
    |> Regex.replace(name, fn _all, hex -> decode_group_codepoint(hex) end)
    |> then(fn decoded ->
      Regex.replace(~r/\\u([D-d][89A-Ba-b][0-9A-Fa-f]{2})\\u([D-d][C-Fc-f][0-9A-Fa-f]{2})/, decoded, fn _all, high, low ->
        decode_group_surrogate_pair(high, low)
      end)
    end)
    |> then(fn decoded ->
      Regex.replace(~r/\\u([0-9A-Fa-f]{4})/, decoded, fn _all, hex ->
        decode_group_codepoint(hex)
      end)
    end)
  end

  defp decode_group_surrogate_pair(high_hex, low_hex) do
    with {high, ""} <- Integer.parse(high_hex, 16),
         {low, ""} <- Integer.parse(low_hex, 16) do
      cp = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
      <<cp::utf8>>
    else
      _ -> "\\u" <> high_hex <> "\\u" <> low_hex
    end
  rescue
    _ -> "\\u" <> high_hex <> "\\u" <> low_hex
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
    literal_exec_decoded_from(s, literal, 0)
  end

  defp literal_exec_decoded_from(s, literal, offset) do
    if lone_surrogate_wtf8?(literal) do
      literal_exec_utf16_unit_from(s, literal, offset)
    else
      case :binary.match(s, literal, scope: {offset, byte_size(s) - offset}) do
        {index, _length} -> exec_result([literal], index, s)
        :nomatch -> nil
      end
    end
  end

  defp literal_exec_utf16_unit_from(s, literal, offset) do
    [unit] = JSString.utf16_code_unit_values(literal)

    s
    |> JSString.utf16_code_unit_values()
    |> Enum.drop(offset)
    |> Enum.find_index(&(&1 == unit))
    |> case do
      nil -> nil
      index -> exec_result([literal], offset + index, s)
    end
  end

  defp decode_hex_escape(hex, digits) do
    case Integer.parse(hex, 16) do
      {cp, ""} when digits == 2 -> <<cp::utf8>>
      {cp, ""} when cp >= 0xD800 and cp <= 0xDFFF -> utf16_unit_to_binary(cp)
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
    unless regexp_match_receiver?(regexp), do: JSThrow.type_error!("RegExp.prototype.matchAll called on incompatible receiver")

    string = QuickBEAM.VM.Interpreter.Values.stringify(string)
    flags = regexp_match_all_observable_flags(regexp)
    observe_match_all_is_regexp(regexp)
    matcher = match_all_species_matcher(regexp, flags)
    offset = regexp_last_index(regexp)

    regexp_string_iterator(
      regexp_match_all_results({matcher, String.contains?(flags, "g")}, string, offset, []),
      matcher,
      string
    )
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

  defp regexp_match_all_flags(regexp), do: regexp_match_all_observable_flags(regexp)

  defp observe_match_all_is_regexp({:obj, _} = regexp), do: Get.get(regexp, {:symbol, "Symbol.match"})
  defp observe_match_all_is_regexp(_regexp), do: :undefined

  defp match_all_species_matcher(regexp, flags) do
    case Get.get(regexp, "constructor") do
      :undefined ->
        regexp

      {:obj, _} = ctor ->
        case Get.get(ctor, {:symbol, "Symbol.species"}) do
          value when value in [nil, :undefined] ->
            regexp

          species ->
            unless Builtin.callable?(species), do: JSThrow.type_error!("RegExp species is not a constructor")
            Invocation.construct_runtime(species, species, [regexp, flags])
        end

      ctor ->
        unless match_all_constructor_object?(ctor), do: JSThrow.type_error!("RegExp constructor is not an object")

        case Get.get(ctor, {:symbol, "Symbol.species"}) do
          value when value in [nil, :undefined] -> :ok
          species -> unless Builtin.callable?(species), do: JSThrow.type_error!("RegExp species is not a constructor")
        end

        regexp
    end
  end

  defp match_all_constructor_object?({:obj, _}), do: true
  defp match_all_constructor_object?(value), do: Builtin.callable?(value)

  defp regexp_match_all_observable_flags(regexp) do
    case Get.get(regexp, "flags") do
      :undefined -> ""
      flags -> regexp_to_string_hint(flags)
    end
  end

  defp maybe_advance_empty_match(regexp, string, match) do
    if Values.stringify(Get.get(match, "0")) == "" do
      this_index = max(Runtime.to_int(Get.get(regexp, "lastIndex")), 0)

      set_last_index!(
        regexp,
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

  defp regexp_match_all_results({{:regexp, nil, source}, global_override}, string, offset, acc)
       when is_binary(source) do
    case literal_exec_from(string, source, offset) do
      nil ->
        Enum.reverse(acc)

      {result, next_offset} ->
        if global_override,
          do: regexp_match_all_results({{:regexp, nil, source}, global_override}, string, next_offset, [result | acc]),
          else: Enum.reverse([result | acc])
    end
  end

  defp regexp_match_all_results({{:regexp, bytecode, source, _ref}, global_override}, string, offset, acc),
    do: regexp_match_all_results({{:regexp, bytecode, source}, global_override}, string, offset, acc)

  defp regexp_match_all_results({{:regexp, bytecode, source} = regexp, global_override}, string, offset, acc)
       when is_binary(bytecode) do
    flags = Get.regexp_flags(bytecode)

    case special_match_results(source, flags, string, global_override) do
      {:ok, results} ->
        results
        |> Enum.filter(fn {_match, index} -> index >= offset end)
        |> maybe_first_match_only(global_override)
        |> Enum.map(fn {match, index} -> exec_result([match], index, string) end)

      :none ->
        regexp_match_all_nif({regexp, global_override}, string, offset, acc, global_override)
    end
  end

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
        |> Enum.filter(fn {_match, index} -> index >= offset end)
        |> maybe_first_match_only(global?)
        |> Enum.map(fn {match, index} -> exec_result([match], index, string) end)

      :none ->
        regexp_match_all_nif(regexp, string, offset, acc, global?)
    end
  end

  defp regexp_match_all_results(_regexp, _string, _offset, acc), do: Enum.reverse(acc)

  defp maybe_first_match_only(results, true), do: results
  defp maybe_first_match_only(results, false), do: Enum.take(results, 1)

  defp regexp_match_all_nif({{:regexp, bytecode, _source} = regexp, global_override}, string, offset, acc, global?) do
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
          do: regexp_match_all_results({regexp, global_override}, string, start + max(len, 1), [result | acc]),
          else: Enum.reverse([result | acc])
    end
  end

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

  defp regexp_search(regexp, args) do
    unless regexp_match_receiver?(regexp),
      do: JSThrow.type_error!("RegExp search receiver is not an object")

    string =
      case args do
        [value | _] -> regexp_search_string(value)
        [] -> Values.stringify(:undefined)
      end

    previous_last_index = Get.get(regexp, "lastIndex")

    unless same_value_zero?(previous_last_index) do
      set_search_last_index!(regexp, 0)
    end

    result = regexp_exec_for_match(regexp, string)
    current_last_index = Get.get(regexp, "lastIndex")

    unless same_value?(current_last_index, previous_last_index) do
      set_search_last_index!(regexp, previous_last_index)
    end

    case result do
      nil -> -1
      {:obj, _} -> Get.get(result, "index")
      _ -> JSThrow.type_error!("RegExp exec result must be an object or null")
    end
  end

  defp regexp_search_string({:symbol, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp regexp_search_string({:symbol, _, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp regexp_search_string(value), do: Values.stringify(value)

  defp same_value_zero?(0), do: true
  defp same_value_zero?(value) when is_float(value) and value == 0.0, do: not negative_zero?(value)
  defp same_value_zero?(_), do: false

  defp same_value?(a, b) do
    if zero_number?(a) and zero_number?(b) do
      negative_zero?(a) == negative_zero?(b)
    else
      a == b
    end
  end

  defp zero_number?(value), do: (is_integer(value) or is_float(value)) and value == 0

  defp negative_zero?(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:short]) == "-0.0"

  defp negative_zero?(_), do: false

  defp set_search_last_index!({:obj, ref} = obj, value) do
    case Heap.get_obj_raw(ref) do
      map when is_map(map) ->
        case Map.get(map, "lastIndex") do
          {:accessor, _getter, nil} ->
            JSThrow.type_error!("Cannot assign to read only property")

          {:accessor, _getter, setter} ->
            Invocation.invoke_with_receiver(setter, [value], Runtime.gas_budget(), obj)

          _ ->
            case Heap.get_prop_desc(ref, "lastIndex") do
              %{writable: false} -> JSThrow.type_error!("Cannot assign to read only property")
              _ -> Put.put(obj, "lastIndex", value)
            end
        end

      _ ->
        Put.put(obj, "lastIndex", value)
    end
  end

  defp set_search_last_index!(regexp, value), do: set_last_index!(regexp, value)

  defp regexp_match(regexp, args) do
    unless regexp_match_receiver?(regexp), do: JSThrow.type_error!("RegExp match receiver is not an object")

    string =
      case args do
        [value | _] -> Values.stringify(value)
        [] -> Values.stringify(:undefined)
      end

    flags = regexp_match_flags(regexp)

    if String.contains?(flags, "g") do
      regexp_match_global(regexp, string, String.contains?(flags, "u") or String.contains?(flags, "v"))
    else
      regexp_exec_for_match(regexp, string)
    end
  end

  defp regexp_match_receiver?({:obj, _}), do: true
  defp regexp_match_receiver?({:regexp, _, _}), do: true
  defp regexp_match_receiver?({:regexp, _, _, _}), do: true
  defp regexp_match_receiver?(%QuickBEAM.VM.Function{}), do: true
  defp regexp_match_receiver?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  defp regexp_match_receiver?({:builtin, _, _}), do: true
  defp regexp_match_receiver?({:bound, _, _, _, _}), do: true
  defp regexp_match_receiver?(_), do: false

  defp regexp_match_flags({:regexp, _, _, ref} = regexp) do
    if RegexpState.has_property?(ref, "flags") do
      regexp_to_string_hint(Get.get(regexp, "flags"))
    else
      regexp_flags_from_properties(regexp)
    end
  end

  defp regexp_match_flags({:regexp, _, _} = regexp), do: regexp_flags_from_properties(regexp)
  defp regexp_match_flags(regexp), do: regexp_to_string_hint(Get.get(regexp, "flags"))

  defp regexp_flags_from_properties(regexp) do
    [
      {"hasIndices", "d"},
      {"global", "g"},
      {"ignoreCase", "i"},
      {"multiline", "m"},
      {"dotAll", "s"},
      {"unicode", "u"},
      {"unicodeSets", "v"},
      {"sticky", "y"}
    ]
    |> Enum.reduce("", fn {property, flag}, acc ->
      if Values.truthy?(Get.get(regexp, property)), do: acc <> flag, else: acc
    end)
  end

  defp regexp_to_string_hint(:undefined), do: "undefined"
  defp regexp_to_string_hint({:symbol, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp regexp_to_string_hint({:symbol, _, _}), do: JSThrow.type_error!("Cannot convert a Symbol value to a string")
  defp regexp_to_string_hint({:obj, _} = obj), do: obj |> Coercion.to_primitive("string") |> Values.stringify()
  defp regexp_to_string_hint(value), do: Values.stringify(value)

  defp regexp_exec_for_match(regexp, string) do
    case regexp_custom_exec(regexp, string) do
      :default -> exec(regexp, [string])
      result -> result
    end
  end

  defp regexp_match_global(regexp, string, unicode?) do
    set_last_index!(regexp, 0)
    regexp_match_global_loop(regexp, string, unicode?, [])
  end

  defp regexp_match_global_loop(regexp, string, unicode?, acc) do
    case regexp_exec_for_match(regexp, string) do
      nil ->
        if acc == [], do: nil, else: Enum.reverse(acc)

      {:obj, _} = result ->
        match = Values.stringify(Get.get(result, "0"))

        if match == "" do
          this_index = max(Runtime.to_int(Get.get(regexp, "lastIndex")), 0)
          set_last_index!(regexp, advance_string_index(string, this_index, unicode?))
        end

        regexp_match_global_loop(regexp, string, unicode?, [match | acc])

      _ ->
        JSThrow.type_error!("RegExp exec result must be an object or null")
    end
  end

  defp regexp_replace(regexp, [string, replacement | _]) do
    unless regexp_match_receiver?(regexp),
      do: JSThrow.type_error!("RegExp replace receiver is not an object")

    JSString.regex_replace(QuickBEAM.VM.Interpreter.Values.stringify(string), regexp, replacement)
  end

  defp regexp_replace(regexp, [string | _]), do: regexp_replace(regexp, [string, :undefined])
  defp regexp_replace(regexp, []), do: regexp_replace(regexp, ["", :undefined])

  defp regexp_custom_exec(regexp, string) do
    case Get.get(regexp, "exec") do
      {:builtin, "exec", _} ->
        :default

      exec_fun when exec_fun not in [nil, :undefined] ->
        unless Builtin.callable?(exec_fun), do: JSThrow.type_error!("RegExp exec is not callable")

        case Invocation.invoke_with_receiver(exec_fun, [string], Runtime.gas_budget(), regexp) do
          nil -> nil
          {:obj, _} = result -> result
          _ -> JSThrow.type_error!("RegExp exec result must be an object or null")
        end

      _ ->
        :default
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
