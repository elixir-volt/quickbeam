defmodule QuickBEAM.BeamVM.Runtime.String do
  @moduledoc "String.prototype methods."

  use QuickBEAM.BeamVM.Builtin

  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Runtime
  alias QuickBEAM.BeamVM.Runtime.RegExp

  # ── Dispatch ──

  proto "charAt" do
    char_at(this, args)
  end

  proto "charCodeAt" do
    char_code_at(this, args)
  end

  proto "codePointAt" do
    code_point_at(this, args)
  end

  proto "indexOf" do
    index_of(this, args)
  end

  proto "lastIndexOf" do
    last_index_of(this, args)
  end

  proto "includes" do
    includes(this, args)
  end

  proto "startsWith" do
    starts_with(this, args)
  end

  proto "endsWith" do
    ends_with(this, args)
  end

  proto "slice" do
    slice(this, args)
  end

  proto "substring" do
    substring(this, args)
  end

  proto "substr" do
    substr(this, args)
  end

  proto "split" do
    split(this, args)
  end

  proto "trim" do
    String.trim(this)
  end

  proto "trimStart" do
    String.trim_leading(this)
  end

  proto "trimEnd" do
    String.trim_trailing(this)
  end

  proto "toUpperCase" do
    String.upcase(this)
  end

  proto "toLowerCase" do
    String.downcase(this)
  end

  proto "repeat" do
    String.duplicate(this, Runtime.to_int(hd(args)))
  end

  proto "padStart" do
    pad(this, args, :start)
  end

  proto "padEnd" do
    pad(this, args, :end)
  end

  proto "replace" do
    replace(this, args)
  end

  proto "replaceAll" do
    replace_all(this, args)
  end

  proto "match" do
    match(this, args)
  end

  proto "matchAll" do
    match_all(this, args)
  end

  proto "search" do
    search(this, args)
  end

  proto "normalize" do
    this
  end

  proto "concat" do
    this <> Enum.map_join(args, &Runtime.stringify/1)
  end

  proto "toString" do
    this
  end

  proto "valueOf" do
    this
  end

  proto "at" do
    string_at(this, args)
  end

  # ── Implementations ──

  defp string_at(s, [idx | _]) when is_binary(s) do
    i = if is_number(idx), do: trunc(idx), else: 0
    len = String.length(s)
    i = if i < 0, do: len + i, else: i
    if i >= 0 and i < len, do: String.at(s, i) || :undefined, else: :undefined
  end

  defp string_at(_, _), do: :undefined

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
    graphemes = String.to_charlist(s)

    if i >= 0 and i < length(graphemes) do
      Enum.at(graphemes, i)
    else
      :nan
    end
  end

  defp char_code_at(_, _), do: :nan

  defp code_point_at(s, [idx | _]) when is_binary(s) do
    i = Runtime.to_int(idx)
    chars = String.to_charlist(s)
    if i >= 0 and i < length(chars), do: Enum.at(chars, i), else: :undefined
  end

  defp code_point_at(_, _), do: :undefined

  defp index_of(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    from =
      case rest do
        [f | _] when is_integer(f) and f >= 0 -> f
        _ -> 0
      end

    if sub == "" do
      min(from, String.length(s))
    else
      search = String.slice(s, from..-1//1)

      case String.split(search, sub, parts: 2) do
        [before, _] -> from + String.length(before)
        _ -> -1
      end
    end
  end

  defp index_of(_, _), do: -1

  defp last_index_of(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    from =
      case rest do
        [f | _] when is_integer(f) -> min(f, String.length(s))
        _ -> String.length(s)
      end

    search = String.slice(s, 0, from + String.length(sub))
    parts = String.split(search, sub)

    if length(parts) > 1 do
      String.length(search) - String.length(List.last(parts)) - String.length(sub)
    else
      -1
    end
  end

  defp last_index_of(_, _), do: -1

  defp includes(s, [sub | _]) when is_binary(s) and is_binary(sub), do: String.contains?(s, sub)
  defp includes(_, _), do: false

  defp starts_with(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    pos =
      case rest do
        [p | _] -> Runtime.to_int(p)
        _ -> 0
      end

    String.starts_with?(String.slice(s, pos..-1//1), sub)
  end

  defp starts_with(_, _), do: false

  defp ends_with(s, [sub | _]) when is_binary(s) and is_binary(sub), do: String.ends_with?(s, sub)
  defp ends_with(_, _), do: false

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

  defp split(s, [sep | _]) when is_binary(s) and is_binary(sep) do
    if sep == "", do: String.codepoints(s), else: String.split(s, sep)
  end

  defp split(s, [nil | _]) when is_binary(s), do: [s]
  defp split(s, []) when is_binary(s), do: [s]
  defp split(_, _), do: []

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
        String.replace(s, pat, Runtime.stringify(replacement), global: false)

      _ ->
        s
    end
  end

  defp replace(s, _), do: s

  defp replace_all(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, _bytecode, _source} = r -> regex_replace(s, r, replacement)
      pat when is_binary(pat) -> String.replace(s, pat, Runtime.stringify(replacement))
      _ -> s
    end
  end

  defp replace_all(s, _), do: s

  defp match(s, [{:regexp, bytecode, _source} | _]) when is_binary(s) and is_binary(bytecode) do
    case RegExp.nif_exec(bytecode, s, 0) do
      nil ->
        nil

      captures ->
        Enum.map(captures, fn
          {start, len} -> String.slice(s, start, len)
          nil -> :undefined
        end)
    end
  end

  defp match(s, [pattern | _]) when is_binary(s) and is_binary(pattern) do
    match(s, [{:regexp, Regex.escape(pattern), ""}])
  end

  defp match(_, _), do: nil

  defp regex_replace(s, {:regexp, _bytecode, source}, replacement) when is_binary(source) do
    case Regex.compile(source) do
      {:ok, re} -> String.replace(s, re, Runtime.stringify(replacement))
      _ -> s
    end
  end

  defp regex_replace(s, _, _), do: s

  defp search(s, [{:regexp, _bc, source} | _]) when is_binary(s) and is_binary(source) do
    case Regex.compile(source) do
      {:ok, re} ->
        case Regex.run(re, s, return: :index) do
          [{start, _} | _] -> start
          _ -> -1
        end

      _ ->
        -1
    end
  end

  defp search(s, [pattern | _]) when is_binary(s) and is_binary(pattern) do
    case String.split(s, pattern, parts: 2) do
      [before, _] -> String.length(before)
      _ -> -1
    end
  end

  defp search(_, _), do: -1

  defp match_all(s, [{:regexp, _bc, source} | _]) when is_binary(s) and is_binary(source) do
    case Regex.compile(source) do
      {:ok, re} ->
        matches = Regex.scan(re, s, return: :index)

        results =
          Enum.map(matches, fn match_indices ->
            Enum.map(match_indices, fn {start, len} -> String.slice(s, start, len) end)
          end)

        ref = make_ref()
        Heap.put_obj(ref, results)
        {:obj, ref}

      _ ->
        ref = make_ref()
        Heap.put_obj(ref, [])
        {:obj, ref}
    end
  end

  defp match_all(_, _) do
    ref = make_ref()
    Heap.put_obj(ref, [])
    {:obj, ref}
  end

  # ── String static methods ──

  static "fromCharCode" do
    Enum.map_join(args, fn n ->
      cp = Runtime.to_int(n)
      if cp >= 0 and cp <= 0x10FFFF, do: <<cp::utf8>>, else: ""
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

    Enum.reduce(0..(len - 1), "", fn i, acc ->
      part = Map.get(raw_map, Integer.to_string(i), "")

      sub =
        if i < length(subs),
          do: Runtime.stringify(Enum.at(subs, i)),
          else: ""

      acc <> Runtime.stringify(part) <> sub
    end)
  end
end
