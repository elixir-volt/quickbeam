defmodule Zig.Parser.Switch do
  defstruct [:subject, :prongs, :location, :label]

  def parse([:LPAREN, subject, :RPAREN, :LBRACE, {:SwitchProngList, prongs}, :RBRACE]) do
    %__MODULE__{subject: subject, prongs: parse_prongs(prongs, [])}
  end

  defp parse_prongs([], []), do: []

  defp parse_prongs(prongs, so_far) do
    case parse_pattern(prongs, []) do
      {pattern, [:|, capture, :COMMA, tag_capture, :|, expr, :COMMA]} ->
        Enum.reverse([{pattern, capture, tag_capture, expr} | so_far])

      {pattern, [:|, capture, :COMMA, tag_capture, :|, expr, :COMMA | rest]} ->
        parse_prongs(rest, [{pattern, capture, tag_capture, expr} | so_far])

      {pattern, [:|, capture, :|, expr, :COMMA]} ->
        Enum.reverse([{pattern, capture, expr} | so_far])

      {pattern, [:|, capture, :|, expr, :COMMA | rest]} ->
        parse_prongs(rest, [{pattern, capture, expr} | so_far])

      {pattern, [:|, :*, capture, :COMMA, tag_capture, :|, expr, :COMMA]} ->
        Enum.reverse([{pattern, {:*, capture}, tag_capture, expr} | so_far])

      {pattern, [:|, :*, capture, :COMMA, tag_capture, :|, expr, :COMMA | rest]} ->
        parse_prongs(rest, [{pattern, {:*, capture}, tag_capture, expr} | so_far])

      {pattern, [:|, :*, capture, :|, expr, :COMMA]} ->
        Enum.reverse([{pattern, {:*, capture}, expr} | so_far])

      {pattern, [:|, :*, capture, :|, expr, :COMMA | rest]} ->
        parse_prongs(rest, [{pattern, {:*, capture}, expr} | so_far])

      {pattern, [:|, capture, :|, expr]} ->
        Enum.reverse([{pattern, capture, expr} | so_far])

      {pattern, [:|, :*, capture, :|, expr]} ->
        Enum.reverse([{pattern, {:*, capture}, expr} | so_far])

      {pattern, [expr, :COMMA]} ->
        Enum.reverse([{pattern, expr} | so_far])

      {pattern, [expr, :COMMA | rest]} ->
        parse_prongs(rest, [{pattern, expr} | so_far])

      {pattern, [expr]} ->
        Enum.reverse([{pattern, expr} | so_far])
    end
  end

  defp parse_pattern([:inline | rest], []) do
    {items, rest} = parse_pattern(rest, [])
    {{:inline, items}, rest}
  end

  defp parse_pattern([{:SwitchItem, items}, :"=>" | rest], so_far) do
    items =
      [parse_items(items, []) | so_far]
      |> Enum.reverse()
      |> List.flatten()

    {items, rest}
  end

  defp parse_pattern([{:SwitchItem, items}, :COMMA, :"=>" | rest], so_far) do
    items =
      [parse_items(items, []) | so_far]
      |> Enum.reverse()
      |> List.flatten()

    {items, rest}
  end

  defp parse_pattern([{:SwitchItem, items}, :COMMA | rest], so_far) do
    parse_pattern(rest, [parse_items(items, []) | so_far])
  end

  defp parse_pattern([:else, :"=>" | rest], []) do
    {:else, rest}
  end

  defp parse_items([left, :..., right | rest], so_far) do
    parse_items(rest, [{:range, left, right} | so_far])
  end

  defp parse_items([item | rest], so_far) do
    parse_items(rest, [item | so_far])
  end

  defp parse_items([], so_far), do: Enum.reverse(so_far)
end
