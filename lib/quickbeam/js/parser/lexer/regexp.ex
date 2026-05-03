defmodule QuickBEAM.JS.Parser.Lexer.Regexp do
  @moduledoc "Regular-expression literal validation helpers for the JavaScript lexer."

  @dialyzer :no_match

  def regexp_flags_error(flags) do
    chars = String.graphemes(flags)

    cond do
      Enum.any?(chars, &(&1 not in ~w[d g i m s u v y])) ->
        "invalid regular expression flags"

      length(chars) != length(Enum.uniq(chars)) ->
        "invalid regular expression flags"

      binary_part?(flags, "u") and binary_part?(flags, "v") ->
        "invalid regular expression flags"

      true ->
        nil
    end
  end

  def regexp_modifier_group_error(pattern), do: regexp_modifier_group_error(pattern, 0)

  defp regexp_modifier_group_error(pattern, offset) when offset >= byte_size(pattern), do: nil

  defp regexp_modifier_group_error(pattern, offset) do
    case :binary.match(pattern, "(?", scope: {offset, byte_size(pattern) - offset}) do
      :nomatch ->
        nil

      {index, 2} ->
        spec_start = index + 2

        if modifier_group_exempt?(pattern, spec_start) do
          regexp_modifier_group_error(pattern, spec_start + 1)
        else
          {spec, next_offset} = read_regexp_modifier_spec(pattern, spec_start)

          if next_offset > 0 and :binary.at(pattern, next_offset - 1) == ?) do
            "invalid group"
          else
            if valid_regexp_modifier_spec?(spec) do
              regexp_modifier_group_error(pattern, next_offset)
            else
              "invalid group"
            end
          end
        end
    end
  end

  defp modifier_group_exempt?(pattern, index) do
    index < byte_size(pattern) and
      :binary.at(pattern, index) in [?:, ?=, ?!, ?<]
  end

  defp read_regexp_modifier_spec(pattern, index),
    do: read_regexp_modifier_spec(pattern, index, [])

  defp read_regexp_modifier_spec(pattern, index, acc) when index >= byte_size(pattern),
    do: {to_string(Enum.reverse(acc)), index}

  defp read_regexp_modifier_spec(pattern, index, acc) do
    ch = :binary.at(pattern, index)

    if ch == ?: or ch == ?) do
      {to_string(Enum.reverse(acc)), index + 1}
    else
      read_regexp_modifier_spec(pattern, index + 1, [ch | acc])
    end
  end

  defp valid_regexp_modifier_spec?(spec) do
    case String.split(spec, "-", parts: 3) do
      [add] ->
        valid_regexp_modifier_flags?(add) and add != ""

      [add, remove] ->
        valid_regexp_modifier_flags?(add) and valid_regexp_modifier_flags?(remove) and add != "" and
          remove != "" and disjoint_modifier_flags?(add, remove)

      _ ->
        false
    end
  end

  defp valid_regexp_modifier_flags?(flags) do
    chars = String.graphemes(flags)
    Enum.all?(chars, &(&1 in ["i", "m", "s"])) and length(chars) == length(Enum.uniq(chars))
  end

  defp disjoint_modifier_flags?(left, right) do
    left = left |> String.graphemes() |> MapSet.new()
    right = right |> String.graphemes() |> MapSet.new()
    MapSet.disjoint?(left, right)
  end

  def regexp_quantifier_error(pattern, flags) do
    cond do
      String.match?(pattern, ~r/^([*+?]|\{\d)/) ->
        "nothing to repeat"

      regexp_quantified_lookbehind?(pattern) ->
        "nothing to repeat"

      binary_part?(flags, "u") and String.match?(pattern, ~r/\(\?[=!][^)]*\)([*+?]|\{\d)/) ->
        "nothing to repeat"

      true ->
        nil
    end
  end

  defp regexp_quantified_lookbehind?(pattern),
    do: regexp_quantified_lookbehind?(pattern, 0)

  defp regexp_quantified_lookbehind?(pattern, offset) when offset >= byte_size(pattern), do: false

  defp regexp_quantified_lookbehind?(pattern, offset) do
    case :binary.match(pattern, "(?<", scope: {offset, byte_size(pattern) - offset}) do
      :nomatch ->
        false

      {index, 3} ->
        marker_offset = index + 3

        if marker_offset < byte_size(pattern) and :binary.at(pattern, marker_offset) in [?=, ?!] do
          close_offset = regexp_group_close_offset(pattern, marker_offset + 1, 1, false)

          if quantified_regexp_atom_at?(pattern, close_offset + 1) do
            true
          else
            regexp_quantified_lookbehind?(pattern, marker_offset + 1)
          end
        else
          regexp_quantified_lookbehind?(pattern, marker_offset)
        end
    end
  end

  defp regexp_group_close_offset(pattern, offset, _depth, _in_class?)
       when offset >= byte_size(pattern),
       do: byte_size(pattern)

  defp regexp_group_close_offset(pattern, offset, depth, in_class?) do
    ch = :binary.at(pattern, offset)

    cond do
      ch == ?\\ ->
        regexp_group_close_offset(pattern, min(offset + 2, byte_size(pattern)), depth, in_class?)

      ch == ?[ and not in_class? ->
        regexp_group_close_offset(pattern, offset + 1, depth, true)

      ch == ?] and in_class? ->
        regexp_group_close_offset(pattern, offset + 1, depth, false)

      in_class? ->
        regexp_group_close_offset(pattern, offset + 1, depth, true)

      ch == ?( ->
        regexp_group_close_offset(pattern, offset + 1, depth + 1, false)

      ch == ?) and depth == 1 ->
        offset

      ch == ?) ->
        regexp_group_close_offset(pattern, offset + 1, depth - 1, false)

      true ->
        regexp_group_close_offset(pattern, offset + 1, depth, false)
    end
  end

  defp quantified_regexp_atom_at?(pattern, offset) when offset >= byte_size(pattern), do: false

  defp quantified_regexp_atom_at?(pattern, offset) do
    ch = :binary.at(pattern, offset)

    ch in [?*, ?+, ??] or
      (ch == ?{ and offset + 1 < byte_size(pattern) and :binary.at(pattern, offset + 1) in ?0..?9)
  end

  def regexp_named_group_error(pattern, flags),
    do: QuickBEAM.JS.Parser.Lexer.Regexp.Groups.regexp_named_group_error(pattern, flags)

  def regexp_unicode_escape_error(pattern, flags),
    do: QuickBEAM.JS.Parser.Lexer.Regexp.Escapes.regexp_unicode_escape_error(pattern, flags)

  def regexp_class_range_error(pattern, flags),
    do: QuickBEAM.JS.Parser.Lexer.Regexp.Properties.regexp_class_range_error(pattern, flags)

  def regexp_property_escape_error(pattern, flags),
    do: QuickBEAM.JS.Parser.Lexer.Regexp.Properties.regexp_property_escape_error(pattern, flags)

  defp binary_part?(binary, part), do: :binary.match(binary, part) != :nomatch
end
