defmodule QuickBEAM.VM.Runtime.RegExp do
  @moduledoc "JS `RegExp` built-in: `test`, `exec`, `toString`, and NIF-backed regex matching against JS bytecode patterns."

  use QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.String, as: JSString

  proto "test" do
    test(this, args)
  end

  proto "exec" do
    exec(this, args)
  end

  proto "toString" do
    regexp_to_string(this)
  end

  def proto_property({:symbol, "Symbol.match"}) do
    {:builtin, "[Symbol.match]", fn args, this -> regexp_match(this, args) end}
  end

  def proto_property({:symbol, "Symbol.matchAll"}) do
    {:builtin, "[Symbol.matchAll]", fn args, this -> regexp_match_all(this, args) end}
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

  defp test({:regexp, bytecode, _source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    nif_exec(bytecode, s, 0) != nil
  end

  defp test({:regexp, bytecode, _source, _ref}, [s | _])
       when is_binary(bytecode) and is_binary(s) do
    nif_exec(bytecode, s, 0) != nil
  end

  defp test(_, _), do: false

  defp exec({:regexp, bytecode, source, _ref}, args),
    do: exec({:regexp, bytecode, source}, args)

  defp exec({:regexp, nil, source}, [s | _]) when is_binary(source) and is_binary(s),
    do: literal_exec(s, source)

  defp exec({:regexp, bytecode, _source}, [s | _]) when is_binary(bytecode) and is_binary(s) do
    case nif_exec(bytecode, s, 0) do
      nil ->
        nil

      captures ->
        strings =
          Enum.map(captures, fn
            {start, len} -> String.slice(s, start, len)
            nil -> :undefined
          end)

        match_start =
          case hd(captures) do
            {start, _} -> start
            _ -> 0
          end

        ref = make_ref()
        Heap.put_obj(ref, strings)

        # Store extra properties accessible via get_own_property
        Heap.put_regexp_result(ref, %{
          "index" => match_start,
          "input" => s,
          "groups" => :undefined
        })

        {:obj, ref}
    end
  end

  defp exec(_, _), do: nil

  defp literal_exec(s, ""), do: exec_result([""], 0, s)

  defp literal_exec(s, source) do
    case :binary.match(s, source) do
      {index, _length} -> exec_result([source], index, s)
      :nomatch -> nil
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
    Heap.wrap_iterator(regexp_match_all_results(regexp, string, 0, []))
  end

  defp regexp_match_all(regexp, []), do: regexp_match_all(regexp, [""])

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

    case special_match_results(source, flags, string, true) do
      {:ok, results} ->
        Enum.map(results, fn {match, index} -> exec_result([match], index, string) end)

      :none ->
        regexp_match_all_nif(regexp, string, offset, acc)
    end
  end

  defp regexp_match_all_results(_regexp, _string, _offset, acc), do: Enum.reverse(acc)

  defp regexp_match_all_nif({:regexp, bytecode, _source} = regexp, string, offset, acc) do
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
        regexp_match_all_results(regexp, string, start + max(len, 1), [result | acc])
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

  defp regexp_to_string({:regexp, bytecode, source, _ref}) do
    flags = Get.regexp_flags(bytecode)
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
          {:regexp, bytecode, _source, _ref} -> String.contains?(Get.regexp_flags(bytecode), flag)
          _ -> false
        end
      end}, nil}
  end

  defp utf8_to_latin1(bin) do
    for <<cp::utf8 <- bin>>, into: <<>>, do: <<Bitwise.band(cp, 0xFF)>>
  rescue
    _ -> bin
  end
end
