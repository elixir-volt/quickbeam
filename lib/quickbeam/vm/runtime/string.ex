defmodule QuickBEAM.VM.Runtime.String do
  @moduledoc "String.prototype methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Get
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
    split(coerce_string_this(this), args)
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
    :string.lowercase(s) |> IO.iodata_to_binary()
  end

  proto "repeat" do
    String.duplicate(coerce_string_this(this), Runtime.to_int(hd(args)))
  end

  proto "padStart" do
    pad(coerce_string_this(this), args, :start)
  end

  proto "padEnd" do
    pad(coerce_string_this(this), args, :end)
  end

  proto "replace" do
    replace(coerce_string_this(this), args)
  end

  proto "replaceAll" do
    replace_all(coerce_string_this(this), args)
  end

  proto "match" do
    match(coerce_string_this(this), args)
  end

  proto "matchAll" do
    match_all(coerce_string_this(this), args)
  end

  proto "localeCompare" do
    s = coerce_string_this(this)
    other = arg(args, 0, "")
    other_str = if is_binary(other), do: other, else: Runtime.stringify(other)

    cond do
      s < other_str -> -1
      s > other_str -> 1
      true -> 0
    end
  end

  proto "search" do
    search(coerce_string_this(this), args)
  end

  proto "normalize" do
    coerce_string_this(this)
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
    |> unwrap_string()
    |> String.codepoints()
    |> iterator_from()
  end

  # ── Implementations ──

  defp unwrap_string({:obj, ref}) do
    case QuickBEAM.VM.Heap.get_obj(ref, %{}) do
      %{"__wrapped_string__" => value} -> value
      _ -> ""
    end
  end

  defp unwrap_string(value), do: Runtime.stringify(value)

  defp string_at(s, [idx | _]) when is_binary(s) do
    i = Runtime.to_int(idx)
    len = String.length(s)
    i = if i < 0, do: len + i, else: i
    if i >= 0 and i < len, do: String.at(s, i) || :undefined, else: :undefined
  end

  defp string_at(s, _) when is_binary(s), do: String.at(s, 0) || :undefined
  defp string_at(_, _), do: :undefined

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
  defp coerce_string_this(val), do: QuickBEAM.VM.Interpreter.Values.stringify(val)

  defp char_at(s, [idx | _]) when is_binary(s) do
    i = Runtime.to_int(idx)

    if i < 0 or i >= String.length(s) do
      ""
    else
      String.at(s, i)
    end
  end

  defp char_at(_, _), do: ""

  defp char_code_at(s, [idx | _]) when is_binary(s) do
    i = Runtime.to_int(idx)
    chars = codepoints(s)

    if i >= 0 and i < tuple_size(chars) do
      case elem(chars, i) do
        cp when cp >= 0xF0000 and cp <= 0xF07FF -> cp - 0xF0000 + 0xD800
        cp -> cp
      end
    else
      :nan
    end
  end

  defp char_code_at(_, _), do: :nan

  defp code_point_at(s, [idx | _]) when is_binary(s) do
    i = Runtime.to_int(idx)
    chars = codepoints(s)
    if i >= 0 and i < tuple_size(chars), do: elem(chars, i), else: :undefined
  end

  defp code_point_at(_, _), do: :undefined

  defp index_of(s, [sub | rest]) when is_binary(s) do
    sub = if is_binary(sub), do: sub, else: Runtime.stringify(sub)

    from =
      case rest do
        [:infinity | _] ->
          String.length(s)

        [f | _] ->
          n = Runtime.to_number(f)

          case n do
            :infinity -> String.length(s)
            :neg_infinity -> 0
            :nan -> 0
            n when is_number(n) -> max(0, trunc(n))
            _ -> 0
          end

        _ ->
          0
      end

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
    sub = if is_binary(sub), do: sub, else: Runtime.stringify(sub)

    from =
      case rest do
        [:neg_infinity | _] -> 0
        [f | _] -> max(0, min(Runtime.to_int(f), String.length(s)))
        _ -> String.length(s)
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
    sub_str = if is_binary(sub), do: sub, else: Runtime.stringify(sub)
    pos = if rest != [], do: max(Runtime.to_int(hd(rest)), 0), else: 0
    String.contains?(String.slice(s, pos..-1//1), sub_str)
  end

  defp includes(_, _), do: false

  defp starts_with(s, [sub | rest]) when is_binary(s) do
    reject_regexp_search!(sub)
    sub = if is_binary(sub), do: sub, else: Runtime.stringify(sub)

    pos =
      case rest do
        [p | _] -> Runtime.to_int(p)
        _ -> 0
      end

    String.starts_with?(String.slice(s, pos..-1//1), sub)
  end

  defp starts_with(_, _), do: false

  defp ends_with(s, [sub | rest]) when is_binary(s) do
    reject_regexp_search!(sub)
    sub_str = if is_binary(sub), do: sub, else: Runtime.stringify(sub)

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

  defp has_lone_surrogate?(s) do
    s
    |> :unicode.characters_to_list(:utf8)
    |> case do
      chars when is_list(chars) ->
        Enum.any?(chars, fn
          cp when cp >= 0xD800 and cp <= 0xDFFF -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp replace_lone_surrogates(s) do
    s
    |> :unicode.characters_to_list(:utf8)
    |> case do
      chars when is_list(chars) ->
        chars
        |> Enum.map(fn
          cp when cp >= 0xD800 and cp <= 0xDFFF -> 0xFFFD
          cp -> cp
        end)
        |> List.to_string()

      _ ->
        s
    end
  end

  defp reject_regexp_search!({:regexp, _, _}) do
    throw(
      {:js_throw, Heap.make_error("First argument must not be a regular expression", "TypeError")}
    )
  end

  defp reject_regexp_search!({:obj, ref}) do
    map = Heap.get_obj(ref, %{})

    if Map.get(map, {:symbol, "Symbol.match"}) != nil and
         Map.get(map, {:symbol, "Symbol.match"}) != :undefined do
      throw(
        {:js_throw,
         Heap.make_error("First argument must not be a regular expression", "TypeError")}
      )
    end
  end

  defp reject_regexp_search!(_), do: :ok

  defp slice(s, args) when is_binary(s) do
    len = String.length(s)

    {start_idx, end_idx} =
      case args do
        [st, en] -> {Runtime.normalize_index(st, len), Runtime.normalize_index(en, len)}
        [st] -> {Runtime.normalize_index(st, len), len}
        [] -> {0, len}
      end

    if start_idx < end_idx, do: String.slice(s, start_idx, end_idx - start_idx), else: ""
  end

  defp substring(s, [start, end_ | _]) when is_binary(s) do
    {a, b} = {Runtime.to_int(start), Runtime.to_int(end_)}
    {s2, e2} = if a > b, do: {b, a}, else: {a, b}
    String.slice(s, max(s2, 0), max(e2 - s2, 0))
  end

  defp substring(s, [start | _]) when is_binary(s),
    do: String.slice(s, max(Runtime.to_int(start), 0)..-1//1)

  defp substring(s, _), do: s

  defp substr(s, [start, len | _]) when is_binary(s),
    do: String.slice(s, Runtime.to_int(start), Runtime.to_int(len))

  defp substr(s, [start | _]) when is_binary(s), do: String.slice(s, Runtime.to_int(start)..-1//1)
  defp substr(s, _), do: s

  defp split(s, [{:regexp, bytecode, _source} | rest])
       when is_binary(s) and is_binary(bytecode) do
    limit =
      case rest do
        [n | _] when is_integer(n) -> n
        _ -> :infinity
      end

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
    limit =
      case rest do
        [n | _] when is_integer(n) -> n
        _ -> :infinity
      end

    if limit == 0 do
      []
    else
      parts = if sep == "", do: String.codepoints(s), else: :binary.split(s, sep, [:global])
      if limit == :infinity, do: parts, else: Enum.take(parts, limit)
    end
  end

  defp split(s, [nil | _]) when is_binary(s), do: [s]
  defp split(s, []) when is_binary(s), do: [s]
  defp split(_, _), do: []

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

  defp pad(s, [len | rest], dir) when is_binary(s) do
    fill =
      case rest do
        [f | _] when is_binary(f) -> String.slice(f, 0, 1)
        _ -> " "
      end

    target = Runtime.to_int(len) - String.length(s)
    if target <= 0, do: s, else: pad_str(s, target, fill, dir)
  end

  defp pad(s, _, _), do: s

  defp pad_str(s, n, fill, :start), do: String.duplicate(fill, n) <> s
  defp pad_str(s, n, fill, :end), do: s <> String.duplicate(fill, n)

  defp replace(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, _bytecode, _source} = r ->
        regex_replace(s, r, replacement)

      pat when is_binary(pat) ->
        :binary.replace(s, pat, Runtime.stringify(replacement))

      _ ->
        s
    end
  end

  defp replace(s, _), do: s

  defp replace_all(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, _bytecode, _source} = r ->
        regex_replace(s, r, replacement)

      pat when is_binary(pat) ->
        :binary.replace(s, pat, Runtime.stringify(replacement), [:global])

      _ ->
        s
    end
  end

  defp replace_all(s, _), do: s

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
          Enum.map(captures, fn
            {start, len} -> binary_part(s, start, len)
            nil -> :undefined
          end)
      end
    end
  end

  defp match(s, [pattern | _]) when is_binary(s) and is_binary(pattern) do
    case QuickBEAM.Native.regexp_compile(Regex.escape(pattern), 0) do
      bytecode when is_binary(bytecode) -> match(s, [{:regexp, bytecode, pattern}])
      _ -> nil
    end
  end

  defp match(_, _), do: nil

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

  defp match_all_with_captures(s, {:regexp, bytecode, _} = re, offset, acc) do
    case RegExp.nif_exec(bytecode, s, offset) do
      nil ->
        Enum.reverse(acc)

      [{start, len} | captures] ->
        strings =
          [binary_part(s, start, len)] ++
            Enum.map(captures, fn
              {cs, cl} -> binary_part(s, cs, cl)
              nil -> :undefined
            end)

        new_offset = start + max(len, 1)

        if new_offset > byte_size(s),
          do: Enum.reverse([strings | acc]),
          else: match_all_with_captures(s, re, new_offset, [strings | acc])
    end
  end

  defp regex_replace(s, {:regexp, bytecode, _source}, replacement)
       when is_binary(s) and is_binary(bytecode) do
    rep = Runtime.stringify(replacement)
    global? = Bitwise.band(:binary.at(bytecode, 0), 1) != 0

    if global? do
      regex_replace_all(s, bytecode, rep, 0, [])
    else
      regex_replace_first(s, bytecode, rep)
    end
  end

  defp regex_replace(s, _, _), do: s

  defp regex_replace_first(s, bytecode, rep) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil ->
        s

      [{match_start, match_len} | _captures] ->
        before = binary_part(s, 0, match_start)

        after_str =
          binary_part(s, match_start + match_len, byte_size(s) - match_start - match_len)

        before <> rep <> after_str
    end
  end

  defp regex_replace_all(s, bytecode, rep, offset, acc) do
    case RegExp.nif_exec(bytecode, s, offset) do
      nil ->
        IO.iodata_to_binary(acc ++ [binary_part(s, offset, byte_size(s) - offset)])

      [{match_start, match_len} | _captures] ->
        before = binary_part(s, offset, match_start - offset)
        next_offset = match_start + max(match_len, 1)
        regex_replace_all(s, bytecode, rep, next_offset, acc ++ [before, rep])
    end
  end

  defp search(s, [{:regexp, bytecode, _source} | _]) when is_binary(s) and is_binary(bytecode) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil -> -1
      [{start, _} | _] -> start
    end
  end

  defp search(s, [pattern | _]) when is_binary(s) and is_binary(pattern) do
    case :binary.match(s, pattern) do
      {pos, _len} -> pos
      :nomatch -> -1
    end
  end

  defp search(_, _), do: -1

  defp match_all(s, [{:regexp, bytecode, _source} = re | _])
       when is_binary(s) and is_binary(bytecode) do
    results = match_all_with_captures(s, re, 0, [])
    ref = make_ref()
    Heap.put_obj(ref, results)
    {:obj, ref}
  end

  defp match_all(_, _) do
    ref = make_ref()
    Heap.put_obj(ref, [])
    {:obj, ref}
  end

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

  defp codepoints(s) do
    case Heap.get_string_codepoints(s) do
      nil ->
        chars = s |> String.to_charlist() |> List.to_tuple()
        Heap.put_string_codepoints(s, chars)
        chars

      chars ->
        chars
    end
  end
end
