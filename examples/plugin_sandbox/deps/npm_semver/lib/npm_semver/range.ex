defmodule NPMSemver.Range do
  @moduledoc """
  npm-compatible semver range parsing and matching.

  A range is a union (`||`) of comparator sets.
  Each comparator set is an intersection (space-separated) of comparators.
  """

  import NimbleParsec

  alias NPMSemver.Version

  defstruct [:sets]

  @type comparator :: {:gte | :lte | :gt | :lt | :eq, Version.t()}
  @type comparator_set :: [comparator]
  @type t :: %__MODULE__{sets: [comparator_set]}

  # --- NimbleParsec tokenizer ---

  ws = ignore(ascii_string([?\s, ?\t], min: 1))
  optional_ws = optional(ws)

  number = integer(min: 1)
  wildcard = choice([string("x"), string("X"), string("*")]) |> replace(:x)
  nr = choice([number, wildcard])

  operator =
    choice([string(">="), string("<="), string("=="), string(">"), string("<"), string("=")])
    |> unwrap_and_tag(:op)

  identifier = ascii_string([?0..?9, ?a..?z, ?A..?Z, ?-], min: 1)

  pre_release =
    ignore(string("-"))
    |> concat(identifier |> repeat(ignore(string(".")) |> concat(identifier)))
    |> tag(:pre)

  build_metadata =
    ignore(string("+"))
    |> concat(identifier |> repeat(ignore(string(".")) |> concat(identifier)))
    |> tag(:build)

  partial =
    nr
    |> optional(ignore(string(".")) |> concat(nr))
    |> optional(ignore(string(".")) |> concat(nr))
    |> optional(pre_release)
    |> optional(build_metadata)
    |> tag(:partial)

  # v-prefix (loose)
  v_partial =
    optional(ignore(string("v")))
    |> concat(partial)

  hyphen = string("-") |> replace(:hyphen) |> unwrap_and_tag(:hyphen_sep)
  or_sep = string("||") |> replace(:or) |> unwrap_and_tag(:or)
  tilde = choice([string("~>"), string("~")]) |> replace(:tilde) |> unwrap_and_tag(:prefix)
  caret = string("^") |> replace(:caret) |> unwrap_and_tag(:prefix)

  token =
    choice([
      or_sep,
      tilde |> concat(optional_ws) |> concat(v_partial),
      caret |> concat(optional_ws) |> concat(v_partial),
      operator |> concat(optional_ws) |> concat(v_partial),
      hyphen,
      v_partial
    ])

  tokens =
    optional_ws
    |> concat(token)
    |> repeat(optional_ws |> concat(token))
    |> concat(optional_ws)
    |> eos()

  defparsecp(:tokenize, tokens)

  # --- Public API ---

  @doc "Parse an npm range string."
  @spec parse(String.t(), keyword()) :: {:ok, t()} | :error
  def parse(range_string, opts \\ []) do
    range_string = String.trim(range_string)

    if range_string in ["", "*", "||"] do
      {:ok, %__MODULE__{sets: [[]]}}
    else
      do_parse(range_string, opts)
    end
  end

  defp do_parse(range_string, opts) do
    include_pre = Keyword.get(opts, :include_prerelease, false)
    loose = Keyword.get(opts, :loose, false)
    range_string = if loose, do: normalize_loose_range(range_string), else: range_string

    with {:ok, tokens, "", _, _, _} <- tokenize(range_string),
         {:ok, sets} <- build_sets(tokens, include_pre) do
      {:ok, %__MODULE__{sets: sets}}
    else
      _ -> :error
    end
  end

  @doc "Check if a version satisfies a range."
  @spec satisfies?(t(), Version.t(), keyword()) :: boolean()
  def satisfies?(%__MODULE__{sets: sets}, %Version{} = version, opts \\ []) do
    include_pre = Keyword.get(opts, :include_prerelease, false)
    Enum.any?(sets, &set_satisfies?(&1, version, include_pre))
  end

  @doc "Convert range to Elixir/hex_solver requirement string."
  @spec to_elixir_string(t()) :: String.t()
  def to_elixir_string(%__MODULE__{sets: sets}) do
    Enum.map_join(sets, " or ", &format_comparator_set/1)
  end

  defp format_comparator_set(comparators) do
    Enum.map_join(comparators, " and ", &format_comparator/1)
  end

  defp format_comparator({op, version}) do
    "#{op_to_string(op)} #{version}"
  end

  defp op_to_string(:gte), do: ">="
  defp op_to_string(:gt), do: ">"
  defp op_to_string(:lte), do: "<="
  defp op_to_string(:lt), do: "<"
  defp op_to_string(:eq), do: "=="

  # --- Token → comparator set builder ---

  defp build_sets(tokens, include_pre) do
    sets =
      tokens
      |> split_on_or()
      |> Enum.map(fn set_tokens -> build_comparator_set(set_tokens, include_pre) end)

    {:ok, sets}
  end

  defp split_on_or(tokens) do
    tokens
    |> Enum.chunk_by(fn
      {:or, _} -> true
      _ -> false
    end)
    |> Enum.reject(fn
      [{:or, _} | _] -> true
      _ -> false
    end)
  end

  defp build_comparator_set(tokens, include_pre) do
    case find_hyphen(tokens) do
      {:hyphen, before, after_} ->
        from = extract_partial(before)
        to = extract_partial(after_)
        expand_hyphen(from, to, include_pre)

      :none ->
        build_comparators(tokens, include_pre)
    end
  end

  defp find_hyphen(tokens) do
    case Enum.split_while(tokens, fn
           {:hyphen_sep, _} -> false
           _ -> true
         end) do
      {before, [{:hyphen_sep, _} | after_]} when before != [] and after_ != [] ->
        {:hyphen, before, after_}

      _ ->
        :none
    end
  end

  defp build_comparators(tokens, include_pre) do
    tokens
    |> chunk_comparators()
    |> Enum.flat_map(fn group -> expand_token_group(group, include_pre) end)
  end

  defp chunk_comparators([]), do: []

  defp chunk_comparators([{:prefix, prefix}, {:partial, _} = p | rest]) do
    [{prefix, p} | chunk_comparators(rest)]
  end

  defp chunk_comparators([{:op, op_str}, {:partial, _} = p | rest]) do
    [{parse_op(op_str), p} | chunk_comparators(rest)]
  end

  defp chunk_comparators([{:partial, _} = p | rest]) do
    [{:bare, p} | chunk_comparators(rest)]
  end

  defp chunk_comparators([_ | rest]) do
    chunk_comparators(rest)
  end

  defp expand_token_group({:tilde, {:partial, parts}}, _include_pre) do
    expand_tilde(to_partial(parts))
  end

  defp expand_token_group({:caret, {:partial, parts}}, _include_pre) do
    expand_caret(to_partial(parts))
  end

  defp expand_token_group({:bare, {:partial, parts}}, include_pre) do
    expand_x_range(to_partial(parts), include_pre)
  end

  defp expand_token_group({op, {:partial, parts}}, include_pre) when is_atom(op) do
    expand_comparator(op, to_partial(parts), include_pre)
  end

  # --- Partial extraction ---

  defp extract_partial(tokens) do
    case tokens do
      [{:partial, parts}] -> to_partial(parts)
      _ -> {nil, nil, nil, nil}
    end
  end

  defp to_partial(parts) do
    {nums, extra} = Enum.split_while(parts, fn x -> is_integer(x) or x == :x end)

    pre =
      case Enum.find(extra, &match?({:pre, _}, &1)) do
        {:pre, p} -> p
        nil -> nil
      end

    nums =
      Enum.map(nums, fn
        :x -> nil
        n -> n
      end)

    case nums do
      [maj] -> {maj, nil, nil, pre}
      [maj, min] -> {maj, min, nil, pre}
      [maj, min, pat] -> {maj, min, pat, pre}
      _ -> {nil, nil, nil, nil}
    end
  end

  # --- Hyphen range ---

  defp expand_hyphen(from, to, include_pre) do
    from_v = pad(from, include_pre)
    to_comps = hyphen_upper(to)
    [{:gte, from_v} | to_comps]
  end

  defp pad({maj, min, pat, pre}, include_pre) do
    v = %Version{
      major: maj || 0,
      minor: min || 0,
      patch: pat || 0,
      pre: parse_pre_list(pre)
    }

    if include_pre and v.pre == [], do: %{v | pre: [0]}, else: v
  end

  defp hyphen_upper({nil, _, _, _}), do: []
  defp hyphen_upper({maj, nil, nil, _}), do: [{:lt, v(maj + 1, 0, 0, [0])}]
  defp hyphen_upper({maj, min, nil, _}), do: [{:lt, v(maj, min + 1, 0, [0])}]
  defp hyphen_upper({maj, min, pat, pre}), do: [{:lte, v(maj, min, pat, parse_pre_list(pre))}]

  # --- Tilde ---

  defp expand_tilde({nil, _, _, _}), do: []
  defp expand_tilde({maj, nil, nil, _}), do: [{:gte, v(maj, 0, 0)}, {:lt, v(maj + 1, 0, 0, [0])}]

  defp expand_tilde({maj, min, nil, _}),
    do: [{:gte, v(maj, min, 0)}, {:lt, v(maj, min + 1, 0, [0])}]

  defp expand_tilde({maj, min, pat, pre}) do
    [{:gte, v(maj, min, pat, parse_pre_list(pre))}, {:lt, v(maj, min + 1, 0, [0])}]
  end

  # --- Caret ---

  defp expand_caret({nil, _, _, _}), do: []
  defp expand_caret({0, nil, nil, _}), do: [{:lt, v(1, 0, 0, [0])}]

  defp expand_caret({0, 0, nil, p}),
    do: [{:gte, v(0, 0, 0, parse_pre_list(p))}, {:lt, v(0, 1, 0, [0])}]

  defp expand_caret({0, m, nil, p}),
    do: [{:gte, v(0, m, 0, parse_pre_list(p))}, {:lt, v(0, m + 1, 0, [0])}]

  defp expand_caret({0, 0, pat, p}),
    do: [{:gte, v(0, 0, pat, parse_pre_list(p))}, {:lt, v(0, 0, pat + 1, [0])}]

  defp expand_caret({0, m, pat, p}),
    do: [{:gte, v(0, m, pat, parse_pre_list(p))}, {:lt, v(0, m + 1, 0, [0])}]

  defp expand_caret({maj, nil, nil, p}) do
    [{:gte, v(maj, 0, 0, parse_pre_list(p))}, {:lt, v(maj + 1, 0, 0, [0])}]
  end

  defp expand_caret({maj, min, nil, p}) do
    [{:gte, v(maj, min, 0, parse_pre_list(p))}, {:lt, v(maj + 1, 0, 0, [0])}]
  end

  defp expand_caret({maj, min, pat, p}) do
    [{:gte, v(maj, min, pat, parse_pre_list(p))}, {:lt, v(maj + 1, 0, 0, [0])}]
  end

  # --- Comparator with operator ---

  defp expand_comparator(op, partial, include_pre)

  defp expand_comparator(op, {nil, _, _, _}, _) when op in [:gt, :lt] do
    [{:lt, v(0, 0, 0, [0])}]
  end

  defp expand_comparator(_op, {nil, _, _, _}, _), do: []

  defp expand_comparator(op, {maj, nil, nil, _}, include_pre) do
    case op do
      :gte -> [{:gte, v(maj, 0, 0)}]
      :gt -> [{:gte, v(maj + 1, 0, 0)}]
      :lte -> [{:lt, v(maj + 1, 0, 0, [0])}]
      :lt -> [{:lt, v(maj, 0, 0, [0])}]
      :eq -> expand_x_range({maj, nil, nil, nil}, include_pre)
    end
  end

  defp expand_comparator(op, {maj, min, nil, _}, include_pre) do
    case op do
      :gte -> [{:gte, v(maj, min, 0, if(include_pre, do: [0], else: []))}]
      :gt -> [{:gte, v(maj, min + 1, 0)}]
      :lte -> [{:lt, v(maj, min + 1, 0, [0])}]
      :lt -> [{:lt, v(maj, min, 0, [0])}]
      :eq -> expand_x_range({maj, min, nil, nil}, include_pre)
    end
  end

  defp expand_comparator(op, {maj, min, pat, pre}, _include_pre) do
    [{op, v(maj, min, pat, parse_pre_list(pre))}]
  end

  # --- X-range ---

  defp expand_x_range(partial, include_pre)

  defp expand_x_range({nil, _, _, _}, _), do: []

  defp expand_x_range({maj, nil, nil, _}, ip) do
    [{:gte, v(maj, 0, 0, if(ip, do: [0], else: []))}, {:lt, v(maj + 1, 0, 0, [0])}]
  end

  defp expand_x_range({maj, min, nil, _}, ip) do
    [{:gte, v(maj, min, 0, if(ip, do: [0], else: []))}, {:lt, v(maj, min + 1, 0, [0])}]
  end

  defp expand_x_range({maj, min, pat, pre}, _ip) do
    [{:eq, v(maj, min, pat, parse_pre_list(pre))}]
  end

  defp normalize_loose_range(string) do
    Regex.replace(~r/(\d+\.\d+\.\d+)([a-zA-Z])/, string, "\\g{1}-\\g{2}")
  end

  defp parse_op(">="), do: :gte
  defp parse_op("<="), do: :lte
  defp parse_op(">"), do: :gt
  defp parse_op("<"), do: :lt
  defp parse_op("="), do: :eq
  defp parse_op("=="), do: :eq

  # --- Helpers ---

  defp v(maj, min, pat, pre \\ []) do
    %Version{major: maj, minor: min, patch: pat, pre: pre}
  end

  defp parse_pre_list(nil), do: []

  defp parse_pre_list(parts) when is_list(parts) do
    Enum.map(parts, fn part ->
      case Integer.parse(part) do
        {n, ""} -> n
        _ -> part
      end
    end)
  end

  # --- Satisfaction ---

  defp set_satisfies?([], version, include_pre) do
    include_pre or version.pre == []
  end

  defp set_satisfies?(comparators, version, include_pre) do
    if not include_pre and version.pre != [] do
      has_matching =
        Enum.any?(comparators, fn {_op, cv} ->
          cv.major == version.major and cv.minor == version.minor and
            cv.patch == version.patch and cv.pre != []
        end)

      has_matching and Enum.all?(comparators, &comparator_match?(&1, version))
    else
      Enum.all?(comparators, &comparator_match?(&1, version))
    end
  end

  defp comparator_match?({op, comp}, version) do
    cmp = Version.compare(version, comp)

    case op do
      :eq -> cmp == :eq
      :gte -> cmp in [:gt, :eq]
      :gt -> cmp == :gt
      :lte -> cmp in [:lt, :eq]
      :lt -> cmp == :lt
    end
  end
end
