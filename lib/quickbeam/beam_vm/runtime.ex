defmodule QuickBEAM.BeamVM.Runtime do
  @moduledoc """
  JS built-in runtime: constructors, prototype methods, global functions.

  All built-ins are plain Elixir functions wrapped in {:builtin, name, fun} tuples.
  The interpreter's call_function dispatches these without entering the bytecode loop.
  """

  # ── Global constructors ──

  def global_bindings do
    %{
      "Object" => {:builtin, "Object", object_constructor()},
      "Array" => {:builtin, "Array", array_constructor()},
      "String" => {:builtin, "String", string_constructor()},
      "Number" => {:builtin, "Number", number_constructor()},
      "Boolean" => {:builtin, "Boolean", boolean_constructor()},
      "Function" => {:builtin, "Function", function_constructor()},
      "Error" => {:builtin, "Error", error_constructor()},
      "TypeError" => {:builtin, "TypeError", error_constructor()},
      "RangeError" => {:builtin, "RangeError", error_constructor()},
      "SyntaxError" => {:builtin, "SyntaxError", error_constructor()},
      "ReferenceError" => {:builtin, "ReferenceError", error_constructor()},
      "Math" => math_object(),
      "JSON" => json_object(),
      "Date" => {:builtin, "Date", date_constructor()},
      "Promise" => {:builtin, "Promise", promise_constructor()},
      "RegExp" => {:builtin, "RegExp", regexp_constructor()},
      "Map" => {:builtin, "Map", map_constructor()},
      "Set" => {:builtin, "Set", set_constructor()},
      "parseInt" => {:builtin, "parseInt", fn args -> builtin_parseInt(args) end},
      "parseFloat" => {:builtin, "parseFloat", fn args -> builtin_parseFloat(args) end},
      "isNaN" => {:builtin, "isNaN", fn args -> builtin_isNaN(args) end},
      "isFinite" => {:builtin, "isFinite", fn args -> builtin_isFinite(args) end},
      "NaN" => :nan,
      "Infinity" => :infinity,
      "undefined" => :undefined,
      "console" => console_object(),
      "Symbol" => {:builtin, "Symbol", symbol_constructor()},
    }
  end

  # ── Property resolution (prototype chain) ──

  def get_property(value, key) when is_binary(key) do
    case get_own_property(value, key) do
      :undefined -> get_prototype_property(value, key)
      val -> val
    end
  end
  def get_property(value, key) when is_integer(key), do: get_property(value, Integer.to_string(key))
  def get_property(_, _), do: :undefined

  defp get_own_property({:obj, ref}, key) do
    case Process.get({:qb_obj, ref}) do
      nil -> :undefined
      map -> Map.get(map, key, :undefined)
    end
  end
  defp get_own_property(list, "length") when is_list(list), do: length(list)
  defp get_own_property(list, key) when is_list(list) and is_integer(key) do
    if key >= 0 and key < length(list), do: Enum.at(list, key), else: :undefined
  end
  defp get_own_property(list, key) when is_list(list) and is_binary(key) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 -> Enum.at(list, idx, :undefined)
      _ -> :undefined
    end
  end
  defp get_own_property(s, "length") when is_binary(s), do: String.length(s)
  defp get_own_property(s, key) when is_binary(s) do
    case String.prototype_method(key) do
      nil -> :undefined
      fun -> {:builtin, key, fun}
    end
  end
  defp get_own_property(n, _) when is_number(n), do: :undefined
  defp get_own_property(true, _), do: :undefined
  defp get_own_property(false, _), do: :undefined
  defp get_own_property(nil, _), do: :undefined
  defp get_own_property(:undefined, _), do: :undefined
  defp get_own_property({:builtin, _name, map}, key) when is_map(map) do
    Map.get(map, key, :undefined)
  end
  defp get_own_property({:regexp, _, _}, key), do: regexp_proto_property(key)
  defp get_own_property(_, _), do: :undefined

  defp get_prototype_property(list, key) when is_list(list), do: array_proto_property(key)
  defp get_prototype_property(s, key) when is_binary(s), do: string_proto_property(key)
  defp get_prototype_property(n, key) when is_number(n), do: number_proto_property(key)
  defp get_prototype_property(true, key), do: boolean_proto_property(key)
  defp get_prototype_property(false, key), do: boolean_proto_property(key)
  defp get_prototype_property({:builtin, "Error", _}, key), do: error_static_property(key)
  defp get_prototype_property({:builtin, "Array", _}, key), do: array_static_property(key)
  defp get_prototype_property({:builtin, "Object", _}, key), do: object_static_property(key)
  defp get_prototype_property(_, _), do: :undefined

  # ── Array.prototype ──

  defp array_proto_property("push"), do: {:builtin, "push", fn args, this -> array_push(this, args) end}
  defp array_proto_property("pop"), do: {:builtin, "pop", fn args, this -> array_pop(this, args) end}
  defp array_proto_property("shift"), do: {:builtin, "shift", fn args, this -> array_shift(this, args) end}
  defp array_proto_property("unshift"), do: {:builtin, "unshift", fn args, this -> array_unshift(this, args) end}
  defp array_proto_property("map"), do: {:builtin, "map", fn args, this, interp -> array_map(this, args, interp) end}
  defp array_proto_property("filter"), do: {:builtin, "filter", fn args, this, interp -> array_filter(this, args, interp) end}
  defp array_proto_property("reduce"), do: {:builtin, "reduce", fn args, this, interp -> array_reduce(this, args, interp) end}
  defp array_proto_property("forEach"), do: {:builtin, "forEach", fn args, this, interp -> array_forEach(this, args, interp) end}
  defp array_proto_property("indexOf"), do: {:builtin, "indexOf", fn args, this -> array_indexOf(this, args) end}
  defp array_proto_property("includes"), do: {:builtin, "includes", fn args, this -> array_includes(this, args) end}
  defp array_proto_property("slice"), do: {:builtin, "slice", fn args, this -> array_slice(this, args) end}
  defp array_proto_property("splice"), do: {:builtin, "splice", fn args, this -> array_splice(this, args) end}
  defp array_proto_property("join"), do: {:builtin, "join", fn args, this -> array_join(this, args) end}
  defp array_proto_property("concat"), do: {:builtin, "concat", fn args, this -> array_concat(this, args) end}
  defp array_proto_property("reverse"), do: {:builtin, "reverse", fn args, this -> array_reverse(this, args) end}
  defp array_proto_property("sort"), do: {:builtin, "sort", fn args, this -> array_sort(this, args) end}
  defp array_proto_property("flat"), do: {:builtin, "flat", fn args, this -> array_flat(this, args) end}
  defp array_proto_property("find"), do: {:builtin, "find", fn args, this, interp -> array_find(this, args, interp) end}
  defp array_proto_property("findIndex"), do: {:builtin, "findIndex", fn args, this, interp -> array_findIndex(this, args, interp) end}
  defp array_proto_property("every"), do: {:builtin, "every", fn args, this, interp -> array_every(this, args, interp) end}
  defp array_proto_property("some"), do: {:builtin, "some", fn args, this, interp -> array_some(this, args, interp) end}
  defp array_proto_property("toString"), do: {:builtin, "toString", fn _args, this -> array_join(this, [","]) end}
  defp array_proto_property(_), do: :undefined

  defp array_push(list, args) when is_list(list) do
    new_list = list ++ args
    put_back_array(list, new_list)
    length(new_list)
  end
  defp array_push({:obj, ref}, args) do
    map = Process.get({:qb_obj, ref}, %{})
    len = Map.get(map, "length", 0)
    new_map = Enum.reduce(Enum.with_index(args), map, fn {val, i}, acc ->
      Map.put(acc, Integer.to_string(len + i), val)
    end) |> Map.put("length", len + length(args))
    Process.put({:qb_obj, ref}, new_map)
    len + length(args)
  end
  defp array_push(_, _), do: 0

  defp array_pop(list, _) when is_list(list) and length(list) > 0 do
    [last | rest] = Enum.reverse(list)
    put_back_array(list, Enum.reverse(rest))
    last
  end
  defp array_pop(_, _), do: :undefined

  defp array_shift(list, _) when is_list(list) and length(list) > 0 do
    [first | rest] = list
    put_back_array(list, rest)
    first
  end
  defp array_shift(_, _), do: :undefined

  defp array_unshift(list, args) when is_list(list) do
    new_list = args ++ list
    put_back_array(list, new_list)
    length(new_list)
  end
  defp array_unshift(_, _), do: 0

  defp array_map(list, [fun | _], interp) when is_list(list) and length(list) > 0 do
    Enum.map(Enum.with_index(list), fn {val, idx} ->
      call_builtin_callback(fun, [val, idx, list], interp)
    end)
  end
  defp array_map(list, _, _), do: list

  defp array_filter(list, [fun | _], interp) when is_list(list) do
    Enum.filter(Enum.with_index(list), fn {val, idx} ->
      js_truthy(call_builtin_callback(fun, [val, idx, list], interp))
    end) |> Enum.map(fn {val, _} -> val end)
  end
  defp array_filter(list, _, _), do: list

  defp array_reduce(list, [fun | rest], interp) when is_list(list) do
    {acc, items} = case rest do
      [init] -> {init, list}
      _ -> {hd(list), tl(list)}
    end
    Enum.reduce(Enum.with_index(items), acc, fn {val, idx}, a ->
      call_builtin_callback(fun, [a, val, idx, list], interp)
    end)
  end
  defp array_reduce([], [_, init | _], _), do: init
  defp array_reduce([val], _, _), do: val

  defp array_forEach(list, [fun | _], interp) when is_list(list) do
    Enum.each(Enum.with_index(list), fn {val, idx} ->
      call_builtin_callback(fun, [val, idx, list], interp)
    end)
    :undefined
  end
  defp array_forEach(_, _, _), do: :undefined

  defp array_indexOf(list, [val | rest]) when is_list(list) do
    from = case rest do [f] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    list |> Enum.drop(from) |> Enum.find_index(&js_strict_eq(&1, val)) |> then(fn
      nil -> -1
      idx -> idx + from
    end)
  end
  defp array_indexOf(_, _), do: -1

  defp array_includes(list, [val | rest]) when is_list(list) do
    from = case rest do [f] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    list |> Enum.drop(from) |> Enum.any?(&js_strict_eq(&1, val))
  end
  defp array_includes(_, _), do: false

  defp array_slice(list, args) when is_list(list) do
    {start_idx, end_idx} = slice_args(list, args)
    list |> Enum.slice(start_idx, max(end_idx - start_idx, 0))
  end
  defp array_slice(_, _), do: []

  defp array_splice(list, [start | rest]) when is_list(list) do
    s = normalize_index(start, length(list))
    {delete_count, items} = case rest do
      [] -> {length(list) - s, []}
      [dc | items] -> {max(min(to_int(dc), length(list) - s), 0), items}
    end
    {removed, remaining} = Enum.split(list, s)
    {removed_head, _} = Enum.split(removed, delete_count)
    new_list = Enum.take(remaining, 0) ++ items ++ Enum.drop(remaining, 0)
    put_back_array(list, Enum.take(list, s) ++ items ++ Enum.drop(list, s + delete_count))
    removed_head
  end
  defp array_splice(list, _), do: list

  defp array_join(list, [sep | _]) when is_list(list), do: array_join_with(list, sep)
  defp array_join(list, []) when is_list(list), do: array_join_with(list, ",")
  defp array_join(_, _), do: ""

  defp array_join_with(list, sep) do
    list |> Enum.map(&js_to_string/1) |> Enum.join(to_string(sep))
  end

  defp array_concat(list, args) when is_list(list) do
    reducer = Enum.reduce(args, fn list -> list end, fn
      a when is_list(a) -> fn acc -> acc ++ a end
      val -> fn acc -> acc ++ [val] end
    end)
    reducer.(list)
  end

  defp array_reverse(list, _) when is_list(list), do: Enum.reverse(list)
  defp array_reverse(_, _), do: []

  defp array_sort(list, _) when is_list(list), do: Enum.sort(list)
  defp array_sort(_, _), do: []

  defp array_flat(list, _) when is_list(list) do
    Enum.flat_map(list, fn
      a when is_list(a) -> a
      val -> [val]
    end)
  end
  defp array_flat(_, _), do: []

  defp array_find(list, [fun | _], interp) when is_list(list) do
    Enum.find_value(Enum.with_index(list), :undefined, fn {val, idx} ->
      if js_truthy(call_builtin_callback(fun, [val, idx, list], interp)), do: val
    end)
  end
  defp array_find(_, _, _), do: :undefined

  defp array_findIndex(list, [fun | _], interp) when is_list(list) do
    Enum.find_value(Enum.with_index(list), -1, fn {val, idx} ->
      if js_truthy(call_builtin_callback(fun, [val, idx, list], interp)), do: idx
    end)
  end
  defp array_findIndex(_, _, _), do: -1

  defp array_every(list, [fun | _], interp) when is_list(list) do
    Enum.all?(Enum.with_index(list), fn {val, idx} ->
      js_truthy(call_builtin_callback(fun, [val, idx, list], interp))
    end)
  end
  defp array_every(_, _, _), do: true

  defp array_some(list, [fun | _], interp) when is_list(list) do
    Enum.any?(Enum.with_index(list), fn {val, idx} ->
      js_truthy(call_builtin_callback(fun, [val, idx, list], interp))
    end)
  end
  defp array_some(_, _, _), do: false

  defp slice_args(list, [start, end_]) do
    s = normalize_index(start, length(list))
    e = if end_ < 0, do: max(length(list) + end_, 0), else: min(to_int(end_), length(list))
    {s, e}
  end
  defp slice_args(list, [start]) do
    {normalize_index(start, length(list)), length(list)}
  end
  defp slice_args(list, []) do
    {0, length(list)}
  end

  defp normalize_index(idx, len) when idx < 0, do: max(len + idx, 0)
  defp normalize_index(idx, len), do: min(idx, len)

  # ── String.prototype ──

  defp string_proto_property("charAt"), do: {:builtin, "charAt", fn args, this -> str_charAt(this, args) end}
  defp string_proto_property("charCodeAt"), do: {:builtin, "charCodeAt", fn args, this -> str_charCodeAt(this, args) end}
  defp string_proto_property("indexOf"), do: {:builtin, "indexOf", fn args, this -> str_indexOf(this, args) end}
  defp string_proto_property("lastIndexOf"), do: {:builtin, "lastIndexOf", fn args, this -> str_lastIndexOf(this, args) end}
  defp string_proto_property("includes"), do: {:builtin, "includes", fn args, this -> str_includes(this, args) end}
  defp string_proto_property("startsWith"), do: {:builtin, "startsWith", fn args, this -> str_startsWith(this, args) end}
  defp string_proto_property("endsWith"), do: {:builtin, "endsWith", fn args, this -> str_endsWith(this, args) end}
  defp string_proto_property("slice"), do: {:builtin, "slice", fn args, this -> str_slice(this, args) end}
  defp string_proto_property("substring"), do: {:builtin, "substring", fn args, this -> str_substring(this, args) end}
  defp string_proto_property("substr"), do: {:builtin, "substr", fn args, this -> str_substr(this, args) end}
  defp string_proto_property("split"), do: {:builtin, "split", fn args, this -> str_split(this, args) end}
  defp string_proto_property("trim"), do: {:builtin, "trim", fn _args, this -> String.trim(this) end}
  defp string_proto_property("trimStart"), do: {:builtin, "trimStart", fn _args, this -> String.trim_leading(this) end}
  defp string_proto_property("trimEnd"), do: {:builtin, "trimEnd", fn _args, this -> String.trim_trailing(this) end}
  defp string_proto_property("toUpperCase"), do: {:builtin, "toUpperCase", fn _args, this -> String.upcase(this) end}
  defp string_proto_property("toLowerCase"), do: {:builtin, "toLowerCase", fn _args, this -> String.downcase(this) end}
  defp string_proto_property("repeat"), do: {:builtin, "repeat", fn args, this -> String.duplicate(this, to_int(hd(args))) end}
  defp string_proto_property("padStart"), do: {:builtin, "padStart", fn args, this -> str_pad(this, args, :start) end}
  defp string_proto_property("padEnd"), do: {:builtin, "padEnd", fn args, this -> str_pad(this, args, :end) end}
  defp string_proto_property("replace"), do: {:builtin, "replace", fn args, this -> str_replace(this, args) end}
  defp string_proto_property("replaceAll"), do: {:builtin, "replaceAll", fn args, this -> str_replaceAll(this, args) end}
  defp string_proto_property("match"), do: {:builtin, "match", fn args, this -> str_match(this, args) end}
  defp string_proto_property("concat"), do: {:builtin, "concat", fn args, this -> this <> Enum.join(Enum.map(args, &js_to_string/1)) end}
  defp string_proto_property("toString"), do: {:builtin, "toString", fn _args, this -> this end}
  defp string_proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}
  defp string_proto_property(_), do: :undefined

  defp str_charAt(s, [idx | _]) when is_binary(s) do
    case String.at(s, to_int(idx)) do
      nil -> ""
      ch -> ch
    end
  end
  defp str_charAt(s, _), do: ""

  defp str_charCodeAt(s, [idx | _]) when is_binary(s) do
    case :binary.at(s, to_int(idx)) do
      :badarg -> :nan
      byte -> byte
    end
  end
  defp str_charCodeAt(_, _), do: :nan

  defp str_indexOf(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    from = case rest do [f | _] when is_integer(f) and f >= 0 -> f; _ -> 0 end
    case :binary.match(s, sub, scope: {:start, from}) do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end
  defp str_indexOf(_, _), do: -1

  defp str_lastIndexOf(s, [sub | _]) when is_binary(s) and is_binary(sub) do
    case :binary.matches(s, sub) |> List.last() do
      {pos, _} -> pos
      nil -> -1
    end
  end
  defp str_lastIndexOf(_, _), do: -1

  defp str_includes(s, [sub | _]) when is_binary(s) and is_binary(sub), do: String.contains?(s, sub)
  defp str_includes(_, _), do: false

  defp str_startsWith(s, [sub | rest]) when is_binary(s) and is_binary(sub) do
    pos = case rest do [p | _] -> to_int(p); _ -> 0 end
    String.starts_with?(String.slice(s, pos..-1//1), sub)
  end
  defp str_startsWith(_, _), do: false

  defp str_endsWith(s, [sub | _]) when is_binary(s) and is_binary(sub), do: String.ends_with?(s, sub)
  defp str_endsWith(_, _), do: false

  defp str_slice(s, args) when is_binary(s) do
    len = String.length(s)
    {start_idx, end_idx} = case args do
      [st, en] -> {norm_idx(st, len), norm_idx(en, len)}
      [st] -> {norm_idx(st, len), len}
      [] -> {0, len}
    end
    if start_idx < end_idx, do: String.slice(s, start_idx, end_idx - start_idx), else: ""
  end

  defp str_substring(s, [start, end_ | _]) when is_binary(s) do
    {a, b} = {to_int(start), to_int(end_)}
    {s2, e2} = if a > b, do: {b, a}, else: {a, b}
    String.slice(s, max(s2, 0), max(e2 - s2, 0))
  end
  defp str_substring(s, [start | _]) when is_binary(s), do: String.slice(s, max(to_int(start), 0)..-1//1)
  defp str_substring(s, _), do: s

  defp str_substr(s, [start, len | _]) when is_binary(s) do
    String.slice(s, to_int(start), to_int(len))
  end
  defp str_substr(s, [start | _]) when is_binary(s), do: String.slice(s, to_int(start)..-1//1)
  defp str_substr(s, _), do: s

  defp str_split(s, [sep | _]) when is_binary(s) and is_binary(sep) do
    if sep == "" do
      String.graphemes(s)
    else
      String.split(s, sep)
    end
  end
  defp str_split(s, [nil | _]) when is_binary(s), do: [s]
  defp str_split(s, []) when is_binary(s), do: [s]
  defp str_split(_, _), do: []

  defp str_pad(s, [len | rest], dir) when is_binary(s) do
    fill = case rest do [f | _] when is_binary(f) -> String.slice(f, 0, 1); _ -> " " end
    target = to_int(len) - String.length(s)
    if target <= 0, do: s, else: pad_str(s, target, fill, dir)
  end
  defp str_pad(s, _, _), do: s

  defp pad_str(s, n, fill, :start) do
    String.duplicate(fill, n) <> s
  end
  defp pad_str(s, n, fill, :end) do
    s <> String.duplicate(fill, n)
  end

  defp str_replace(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, pat, flags} -> regex_replace(s, pat, flags, replacement, false)
      pat when is_binary(pat) -> String.replace(s, pat, js_to_string(replacement), global: false)
      _ -> s
    end
  end
  defp str_replace(s, _), do: s

  defp str_replaceAll(s, [pattern, replacement | _]) when is_binary(s) do
    case pattern do
      {:regexp, pat, flags} -> regex_replace(s, pat, flags, replacement, true)
      pat when is_binary(pat) -> String.replace(s, pat, js_to_string(replacement))
      _ -> s
    end
  end
  defp str_replaceAll(s, _), do: s

  defp str_match(s, [{:regexp, pat, _flags} | _]) when is_binary(s) do
    case Regex.run(Regex.compile!(pat), s, return: :index) do
      nil -> nil
      matches -> Enum.map(matches, fn {start, len} -> String.slice(s, start, len) end)
    end
  end
  defp str_match(_, _), do: nil

  defp regex_replace(s, pat, _flags, replacement, global) do
    regex = Regex.compile!(pat)
    String.replace(s, regex, js_to_string(replacement))
  end

  # ── Number.prototype ──

  defp number_proto_property("toString"), do: {:builtin, "toString", fn args, this -> number_toString(this, args) end}
  defp number_proto_property("toFixed"), do: {:builtin, "toFixed", fn args, this -> number_toFixed(this, args) end}
  defp number_proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}
  defp number_proto_property(_), do: :undefined

  defp number_toString(n, [radix | _]) when is_number(n) do
    case to_int(radix) do
      10 -> Float.to_string(n * 1.0) |> String.trim_trailing(".0")
      16 -> Integer.to_string(trunc(n), 16)
      2 -> Integer.to_string(trunc(n), 2)
      8 -> Integer.to_string(trunc(n), 8)
      _ -> js_to_string(n)
    end
  end
  defp number_toString(n, _), do: js_to_string(n)

  defp number_toFixed(n, [digits | _]) when is_number(n) do
    :erlang.float_to_binary(n * 1.0, [decimals: to_int(digits), compact: false])
  end
  defp number_toFixed(n, _), do: js_to_string(n)

  # ── Boolean.prototype ──
  defp boolean_proto_property("toString"), do: {:builtin, "toString", fn _args, this -> Atom.to_string(this) end}
  defp boolean_proto_property("valueOf"), do: {:builtin, "valueOf", fn _args, this -> this end}
  defp boolean_proto_property(_), do: :undefined

  # ── Math object ──

  defp math_object do
    {:builtin, "Math", %{
      "floor" => {:builtin, "floor", fn [a | _] -> floor(to_float(a)) end},
      "ceil" => {:builtin, "ceil", fn [a | _] -> ceil(to_float(a)) end},
      "round" => {:builtin, "round", fn [a | _] -> round(to_float(a)) end},
      "abs" => {:builtin, "abs", fn [a | _] -> abs(a) end},
      "max" => {:builtin, "max", fn args -> Enum.max(Enum.map(args, &to_float/1)) end},
      "min" => {:builtin, "min", fn args -> Enum.min(Enum.map(args, &to_float/1)) end},
      "sqrt" => {:builtin, "sqrt", fn [a | _] -> :math.sqrt(to_float(a)) end},
      "pow" => {:builtin, "pow", fn [a, b | _] -> :math.pow(to_float(a), to_float(b)) end},
      "random" => {:builtin, "random", fn _ -> :rand.uniform() end},
      "trunc" => {:builtin, "trunc", fn [a | _] -> trunc(to_float(a)) end},
      "sign" => {:builtin, "sign", fn [a | _] -> if a > 0, do: 1, else: if a < 0, do: -1, else: 0 end},
      "log" => {:builtin, "log", fn [a | _] -> :math.log(to_float(a)) end},
      "log2" => {:builtin, "log2", fn [a | _] -> :math.log2(to_float(a)) end},
      "log10" => {:builtin, "log10", fn [a | _] -> :math.log10(to_float(a)) end},
      "sin" => {:builtin, "sin", fn [a | _] -> :math.sin(to_float(a)) end},
      "cos" => {:builtin, "cos", fn [a | _] -> :math.cos(to_float(a)) end},
      "tan" => {:builtin, "tan", fn [a | _] -> :math.tan(to_float(a)) end},
      "PI" => :math.pi(),
      "E" => :math.exp(1),
      "LN2" => :math.log(2),
      "LN10" => :math.log(10),
      "LOG2E" => :math.log2(:math.exp(1)),
      "LOG10E" => :math.log10(:math.exp(1)),
      "SQRT2" => :math.sqrt(2),
      "SQRT1_2" => :math.sqrt(2) / 2,
      "MAX_SAFE_INTEGER" => 9007199254740991,
      "MIN_SAFE_INTEGER" => -9007199254740991,
    }}
  end

  # ── JSON ──

  defp json_object do
    {:builtin, "JSON", %{
      "parse" => {:builtin, "parse", fn [s | _] -> json_parse(s) end},
      "stringify" => {:builtin, "stringify", fn args -> json_stringify(args) end},
    }}
  end

  defp json_parse(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, val} -> json_to_js(val)
      {:error, _} -> throw({:js_throw, "SyntaxError: JSON.parse"})
    end
  end

  defp json_to_js(nil), do: nil
  defp json_to_js(val) when is_map(val) do
    ref = make_ref()
    map = Map.new(val, fn {k, v} -> {k, json_to_js(v)} end)
    Process.put({:qb_obj, ref}, map)
    {:obj, ref}
  end
  defp json_to_js(val) when is_list(val), do: Enum.map(val, &json_to_js/1)
  defp json_to_js(val), do: val

  defp json_stringify([val | _]) do
    case Jason.encode(js_to_json(val)) do
      {:ok, s} -> s
      {:error, _} -> :undefined
    end
  end

  defp js_to_json({:obj, ref}) do
    case Process.get({:qb_obj, ref}) do
      nil -> %{}
      map -> Map.new(map, fn {k, v} -> {to_string(k), js_to_json(v)} end)
    end
  end
  defp js_to_json(:undefined), do: nil
  defp js_to_json(:nan), do: nil
  defp js_to_json(:infinity), do: nil
  defp js_to_json(list) when is_list(list), do: Enum.map(list, &js_to_json/1)
  defp js_to_json(val), do: val

  # ── Object static methods ──

  defp object_static_property("keys"), do: {:builtin, "keys", fn args -> obj_keys(args) end}
  defp object_static_property("values"), do: {:builtin, "values", fn args -> obj_values(args) end}
  defp object_static_property("entries"), do: {:builtin, "entries", fn args -> obj_entries(args) end}
  defp object_static_property("assign"), do: {:builtin, "assign", fn args -> obj_assign(args) end}
  defp object_static_property("freeze"), do: {:builtin, "freeze", fn [obj | _] -> obj end}
  defp object_static_property("is"), do: {:builtin, "is", fn [a, b | _] -> js_strict_eq(a, b) end}
  defp object_static_property("create"), do: {:builtin, "create", fn _ -> obj_new() end}
  defp object_static_property(_), do: :undefined

  defp obj_keys([{:obj, ref} | _]) do
    map = Process.get({:qb_obj, ref}, %{})
    Map.keys(map)
  end
  defp obj_keys([map | _]) when is_map(map), do: Map.keys(map)
  defp obj_keys(_), do: []

  defp obj_values([{:obj, ref} | _]) do
    map = Process.get({:qb_obj, ref}, %{})
    Map.values(map)
  end
  defp obj_values([map | _]) when is_map(map), do: Map.values(map)
  defp obj_values(_), do: []

  defp obj_entries([{:obj, ref} | _]) do
    map = Process.get({:qb_obj, ref}, %{})
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end
  defp obj_entries([map | _]) when is_map(map) do
    Enum.map(Map.to_list(map), fn {k, v} -> [k, v] end)
  end
  defp obj_entries(_), do: []

  defp obj_assign([target | sources]) do
    Enum.reduce(sources, target, fn
      {:obj, ref}, {:obj, tref} ->
        src_map = Process.get({:qb_obj, ref}, %{})
        tgt_map = Process.get({:qb_obj, tref}, %{})
        Process.put({:qb_obj, tref}, Map.merge(tgt_map, src_map))
        {:obj, tref}
      map, {:obj, tref} when is_map(map) ->
        tgt_map = Process.get({:qb_obj, tref}, %{})
        Process.put({:qb_obj, tref}, Map.merge(tgt_map, map))
        {:obj, tref}
      _, acc -> acc
    end)
  end

  # ── Array static methods ──

  defp array_static_property("isArray"), do: {:builtin, "isArray", fn [val | _] -> is_list(val) end}
  defp array_static_property("from"), do: {:builtin, "from", fn args -> array_from(args) end}
  defp array_static_property("of"), do: {:builtin, "of", fn args -> args end}
  defp array_static_property(_), do: :undefined

  defp array_from([{:obj, ref} | _]) do
    map = Process.get({:qb_obj, ref}, %{})
    len = Map.get(map, "length", 0)
    for i <- 0..(len - 1), do: Map.get(map, Integer.to_string(i), :undefined)
  end
  defp array_from([list | _]) when is_list(list), do: list
  defp array_from([s | _]) when is_binary(s), do: String.graphemes(s)
  defp array_from(_), do: []

  # ── Error ──

  defp error_static_property(_), do: :undefined

  # ── RegExp ──

  defp regexp_proto_property("test"), do: {:builtin, "test", fn args, this -> regexp_test(this, args) end}
  defp regexp_proto_property("exec"), do: {:builtin, "exec", fn args, this -> regexp_exec(this, args) end}
  defp regexp_proto_property("source"), do: {:builtin, "source", fn _args, this -> regexp_source(this) end}
  defp regexp_proto_property("flags"), do: {:builtin, "flags", fn _args, this -> regexp_flags(this) end}
  defp regexp_proto_property("toString"), do: {:builtin, "toString", fn _args, this -> regexp_toString(this) end}
  defp regexp_proto_property(_), do: :undefined

  defp regexp_test({:regexp, pat, _}, [s | _]) when is_binary(pat) and is_binary(s) do
    String.match?(s, Regex.compile!(pat))
  end
  defp regexp_test(_, _), do: false

  defp regexp_exec({:regexp, pat, flags}, [s | _]) when is_binary(pat) and is_binary(s) do
    regex = Regex.compile!(pat, if(is_binary(flags) and String.contains?(flags, "g"), do: "g", else: ""))
    case Regex.run(regex, s, return: :index) do
      nil -> nil
      matches ->
        result = Enum.map(matches, fn {start, len} -> String.slice(s, start, len) end)
        ref = make_ref()
        Process.put({:qb_obj, ref}, %{
          "0" => hd(result),
          "index" => elem(hd(matches), 0),
          "input" => s,
          "groups" => :undefined,
          "length" => length(result)
        })
        {:obj, ref}
    end
  end
  defp regexp_exec(_, _), do: nil

  defp regexp_source({:regexp, pat, _}), do: pat
  defp regexp_source(_), do: "(?:)"
  defp regexp_flags({:regexp, _, f}), do: f || ""
  defp regexp_flags(_), do: ""
  defp regexp_toString({:regexp, pat, f}), do: "/#{pat}/#{f || ""}"

  # ── Console ──

  defp console_object do
    ref = make_ref()
    Process.put({:qb_obj, ref}, %{
      "log" => {:builtin, "log", fn args ->
        IO.puts(Enum.map(args, &js_to_string/1) |> Enum.join(" "))
        :undefined
      end},
      "warn" => {:builtin, "warn", fn args ->
        IO.warn(Enum.map(args, &js_to_string/1) |> Enum.join(" "))
        :undefined
      end},
      "error" => {:builtin, "error", fn args ->
        IO.puts(:stderr, Enum.map(args, &js_to_string/1) |> Enum.join(" "))
        :undefined
      end},
      "info" => {:builtin, "info", fn args ->
        IO.puts(Enum.map(args, &js_to_string/1) |> Enum.join(" "))
        :undefined
      end},
      "debug" => {:builtin, "debug", fn args ->
        IO.puts(Enum.map(args, &js_to_string/1) |> Enum.join(" "))
        :undefined
      end},
    })
    {:obj, ref}
  end

  # ── Constructors ──

  defp object_constructor, do: fn _args -> obj_new() end
  defp array_constructor do
    fn
      [n] when is_integer(n) and n >= 0 -> List.duplicate(:undefined, n)
      args -> args
    end
  end
  defp string_constructor, do: fn args -> js_to_string(List.first(args, "")) end
  defp number_constructor, do: fn args -> to_number(List.first(args, 0)) end
  defp boolean_constructor, do: fn args -> js_truthy(List.first(args, false)) end
  defp function_constructor, do: fn _args -> :undefined end

  defp error_constructor do
    fn args ->
      msg = List.first(args, "")
      ref = make_ref()
      Process.put({:qb_obj, ref}, %{"message" => js_to_string(msg)})
      {:obj, ref}
    end
  end

  defp date_constructor do
    fn args ->
      ms = case args do
        [] -> System.system_time(:millisecond)
        [n | _] when is_number(n) -> n
        [s | _] when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
            _ -> :nan
          end
        _ -> :nan
      end
      ref = make_ref()
      Process.put({:qb_obj, ref}, %{"valueOf" => ms})
      {:obj, ref}
    end
  end

  defp promise_constructor, do: fn _args -> {:builtin, "Promise", %{}} end
  defp regexp_constructor do
    fn [pattern | rest] ->
      flags = case rest do [f | _] when is_binary(f) -> f; _ -> "" end
      pat = case pattern do
        {:regexp, p, _} -> p
        s when is_binary(s) -> s
        _ -> ""
      end
      {:regexp, pat, flags}
    end
  end
  defp map_constructor, do: fn _args -> obj_new() end
  defp set_constructor, do: fn _args -> obj_new() end
  defp symbol_constructor, do: fn args -> {:symbol, List.first(args, "")} end

  # ── Global functions ──

  defp builtin_parseInt([s | _]) when is_binary(s) do
    s = String.trim_leading(s)
    case Integer.parse(s) do
      {n, _} -> n
      :error -> :nan
    end
  end
  defp builtin_parseInt([n | _]) when is_number(n), do: trunc(n)
  defp builtin_parseInt(_), do: :nan

  defp builtin_parseFloat([s | _]) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      {f, _} -> f
      :error -> :nan
    end
  end
  defp builtin_parseFloat([n | _]) when is_number(n), do: n * 1.0
  defp builtin_parseFloat(_), do: :nan

  defp builtin_isNaN([:nan | _]), do: true
  defp builtin_isNaN([n | _]) when is_number(n), do: false
  defp builtin_isNaN([s | _]) when is_binary(s) do
    case Float.parse(s) do
      :error -> true
      _ -> false
    end
  end
  defp builtin_isNaN(_), do: true

  defp builtin_isFinite([n | _]) when is_number(n) and n != :infinity and n != :neg_infinity and n != :nan, do: true
  defp builtin_isFinite(_), do: false

  # ── Helpers ──

  defp obj_new do
    ref = make_ref()
    Process.put({:qb_obj, ref}, %{})
    {:obj, ref}
  end

  defp put_back_array(original, new_list) when is_list(original) do
    # If the array was stored in a local, this is a no-op
    # (the caller must update the local themselves)
    :ok
  end

  def call_builtin_callback(fun, args, interp) do
    case fun do
      {:builtin, _, cb} when is_function(cb, 1) -> cb.(args)
      {:builtin, _, cb} when is_function(cb, 2) -> cb.(args, nil)
      {:builtin, _, cb} when is_function(cb, 3) -> cb.(args, nil, interp)
      %QuickBEAM.BeamVM.Bytecode.Function{} = f ->
        QuickBEAM.BeamVM.Interpreter.invoke_function(f, args, 10_000_000)
      {:closure, _, %QuickBEAM.BeamVM.Bytecode.Function{}} = c ->
        QuickBEAM.BeamVM.Interpreter.invoke_closure(c, args, 10_000_000)
      f when is_function(f) -> apply(f, args)
      _ -> :undefined
    end
  end

  defp js_truthy(nil), do: false
  defp js_truthy(:undefined), do: false
  defp js_truthy(false), do: false
  defp js_truthy(0), do: false
  defp js_truthy(""), do: false
  defp js_truthy(_), do: true

  defp js_strict_eq(a, b), do: a === b

  defp js_to_string(:undefined), do: "undefined"
  defp js_to_string(nil), do: "null"
  defp js_to_string(true), do: "true"
  defp js_to_string(false), do: "false"
  defp js_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp js_to_string(n) when is_float(n) do
    s = Float.to_string(n)
    if String.ends_with?(s, ".0"), do: String.slice(s, 0..-3//1), else: s
  end
  defp js_to_string(s) when is_binary(s), do: s
  defp js_to_string({:obj, ref}) do
    map = Process.get({:qb_obj, ref}, %{})
    if map == %{}, do: "[object Object]", else: "[object Object]"
  end
  defp js_to_string(list) when is_list(list), do: Enum.map(list, &js_to_string/1) |> Enum.join(",")
  defp js_to_string(_), do: ""

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(_), do: 0

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: 0.0

  defp to_number(n) when is_number(n), do: n
  defp to_number(true), do: 1
  defp to_number(false), do: 0
  defp to_number(nil), do: 0
  defp to_number(:undefined), do: :nan
  defp to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _} -> f
      :error -> :nan
    end
  end
  defp to_number(_), do: :nan

  defp norm_idx(idx, len) when idx < 0, do: max(len + idx, 0)
  defp norm_idx(idx, len), do: min(idx, len)
end
