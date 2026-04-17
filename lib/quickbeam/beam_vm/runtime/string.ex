defmodule QuickBEAM.BeamVM.Runtime.StringProto do
  @moduledoc "String.prototype methods."

  alias QuickBEAM.BeamVM.Runtime

  # ── Dispatch ──

  def proto_property("charAt"), do: {:builtin, "charAt", fn args, this -> char_at(this, args) end}
  def proto_property("charCodeAt"), do: {:builtin, "charCodeAt", fn args, this -> char_code_at(this, args) end}
  def proto_property("indexOf"), do: {:builtin, "indexOf", fn args, this -> index_of(this, args) end}
  def proto_property("lastIndexOf"), do: {:builtin, "lastIndexOf", fn args, this -> last_index_of(this, args) end}
  def proto_property("includes"), do: {:builtin, "includes", fn args, this -> includes(this, args) end}
  def proto_property("startsWith"), do: {:builtin, "startsWith", fn args, this -> starts_with(this, args) end}
  def proto_property("endsWith"), do: {:builtin, "endsWith", fn args, this -> ends_with(this, args) end}
  def proto_property("slice"), do: {:builtin, "slice", fn args, this -> slice(this, args) end}
  def proto_property("substring"), do: {:builtin, "substring", fn args, this -> substring(this, args) end}
  def proto_property("substr"), do: {:builtin, "substr", fn args, this -> substr(this, args) end}
  def proto_property("split"), do: {:builtin, "split", fn args, this -> split(this, args) end}
  def proto_property("trim"), do: {:builtin, "trim", fn _args, this -> String.trim(this) end}
  def proto_property("trimStart"), do: {:builtin, "trimStart", fn _args, this -> String.trim_leading(this) end}
  def proto_property("trimEnd"), do: {:builtin, "trimEnd", fn _args, this -> String.trim_trailing(this) end}
  def proto_property("toUpperCase"), do: {:builtin, "toUpperCase", fn _args, this -> String.upcase(this) end}
  def proto_property("toLowerCase"), do: {:builtin, "toLowerCase", fn _args, this -> String.downcase(this) end}
  def proto_property("repeat"), do: {:builtin, "repeat", fn args, this -> String.duplicate(this, Runtime.to_int(hd(args))) end}
  def proto_property("padStart"), do: {:builtin, "padStart", fn args, this -> pad(this, args, :start) end}
  def proto_property("padEnd"), do: {:builtin, "padEnd", fn args, this -> pad(this, args, :end) end}
  def proto_property("replace"), do: {:builtin, "replace", fn args, this -> replace(this, args) end}
  def proto_property("replaceAll"), do: {:builtin, "replaceAll", fn args, this -> replace_all(this, args) end}
  def proto_property("match"), do: {:builtin, "match", fn args, this -> match(this, args) end}
  def proto_property("matchAll"), do: {:builtin, "matchAll", fn args, this -> match_all(this, args) end}
  def proto_property("search"), do: {:builtin, "search", fn args, this -> search(this, args) end}
  def proto_property("normalize"), do: {:builtin, "normalize", fn _args, this -> this end}
  def proto_property("concat"), do: {:builtin, "concat", fn args, this -> this <> Enum.join(Enum.map(args, &Runtime.js_to_string/1)) end}
  def proto_property("toString"), do: {:builtin, "toString", fn _args, this -> this end}
  def proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}
  def proto_property(_), do: :undefined

  # ── Implementations ──

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
    case :binary.at(s, Runtime.to_int(idx)) do
      :badarg -> :nan
      byte -> byte
    end
  end
  defp char_code_at(_, _), do: :nan

  defp index_of(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    from = case rest do [f | _] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    if sub == "" do
      min(from, String.length(s))
    else
      case :binary.match(s, sub) do
        {pos, _} when pos >= from -> pos
        {_pos, _} ->
          case :binary.match(s, sub, [{:scope, {from, byte_size(s) - from}}]) do
            {pos2, _} -> pos2
            :nomatch -> -1
          end
        :nomatch -> -1
      end
    end
  end
  defp index_of(_, _), do: -1

  defp last_index_of(s, [sub | _]) when is_binary(s) and is_binary(sub) do
    case :binary.matches(s, sub) |> List.last() do
      {pos, _} -> pos
      nil -> -1
    end
  end
  defp last_index_of(_, _), do: -1

  defp includes(s, [sub | _]) when is_binary(s) and is_binary(sub), do: String.contains?(s, sub)
  defp includes(_, _), do: false

  defp starts_with(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    pos = case rest do [p | _] -> Runtime.to_int(p); _ -> 0 end
    String.starts_with?(String.slice(s, pos..-1//1), sub)
  end
  defp starts_with(_, _), do: false

  defp ends_with(s, [sub | _]) when is_binary(s) and is_binary(sub), do: String.ends_with?(s, sub)
  defp ends_with(_, _), do: false

  defp slice(s, args) when is_binary(s) do
    len = String.length(s)
    {start_idx, end_idx} = case args do
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
  defp substring(s, [start | _]) when is_binary(s), do: String.slice(s, max(Runtime.to_int(start), 0)..-1//1)
  defp substring(s, _), do: s

  defp substr(s, [start, len | _]) when is_binary(s), do: String.slice(s, Runtime.to_int(start), Runtime.to_int(len))
  defp substr(s, [start | _]) when is_binary(s), do: String.slice(s, Runtime.to_int(start)..-1//1)
  defp substr(s, _), do: s

  defp split(s, [sep | _]) when is_binary(s) and is_binary(sep) do
    if sep == "", do: String.graphemes(s), else: String.split(s, sep)
  end
  defp split(s, [nil | _]) when is_binary(s), do: [s]
  defp split(s, []) when is_binary(s), do: [s]
  defp split(_, _), do: []

  defp pad(s, [len | rest], dir) when is_binary(s) do
    fill = case rest do [f | _] when is_binary(f) -> String.slice(f, 0, 1); _ -> " " end
    target = Runtime.to_int(len) - String.length(s)
    if target <= 0, do: s, else: pad_str(s, target, fill, dir)
  end
  defp pad(s, _, _), do: s

  defp pad_str(s, n, fill, :start), do: String.duplicate(fill, n) <> s
  defp pad_str(s, n, fill, :end), do: s <> String.duplicate(fill, n)

  defp replace(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, _bytecode, _source} = r -> regex_replace(s, r, replacement)
      pat when is_binary(pat) -> String.replace(s, pat, Runtime.js_to_string(replacement), global: false)
      _ -> s
    end
  end
  defp replace(s, _), do: s

  defp replace_all(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, _bytecode, _source} = r -> regex_replace(s, r, replacement)
      pat when is_binary(pat) -> String.replace(s, pat, Runtime.js_to_string(replacement))
      _ -> s
    end
  end
  defp replace_all(s, _), do: s

  defp match(s, [{:regexp, _bytecode, source} | _]) when is_binary(s) do
    case Regex.compile(source) do
      {:ok, re} ->
        case Regex.run(re, s, return: :index) do
          nil -> nil
          matches -> Enum.map(matches, fn {start, len} -> String.slice(s, start, len) end)
        end
      _ -> nil
    end
  end
  defp match(s, [pattern | _]) when is_binary(s) and is_binary(pattern) do
    match(s, [{:regexp, Regex.escape(pattern), ""}])
  end
  defp match(_, _), do: nil

  defp regex_replace(s, {:regexp, _bytecode, source}, replacement) when is_binary(source) do
    case Regex.compile(source) do
      {:ok, re} -> String.replace(s, re, Runtime.js_to_string(replacement))
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
      _ -> -1
    end
  end
  defp search(s, [pattern | _]) when is_binary(s) and is_binary(pattern) do
    case :binary.match(s, pattern) do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end
  defp search(_, _), do: -1

  defp match_all(s, [{:regexp, _bc, source} | _]) when is_binary(s) and is_binary(source) do
    case Regex.compile(source) do
      {:ok, re} ->
        matches = Regex.scan(re, s, return: :index)
        results = Enum.map(matches, fn match_indices ->
          Enum.map(match_indices, fn {start, len} -> String.slice(s, start, len) end)
        end)
        ref = make_ref()
        QuickBEAM.BeamVM.Heap.put_obj(ref, results)
        {:obj, ref}
      _ ->
        ref = make_ref()
        QuickBEAM.BeamVM.Heap.put_obj(ref, [])
        {:obj, ref}
    end
  end
  defp match_all(_, _) do
    ref = make_ref()
    QuickBEAM.BeamVM.Heap.put_obj(ref, [])
    {:obj, ref}
  end
end
