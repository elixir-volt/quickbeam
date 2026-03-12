defmodule Zig.Parser.For do
  defstruct [:block, :label, :else, :location, inline: false, iterators: [], captures: []]

  @terminators [[], [:SEMICOLON]]

  def post_traverse(rest, [{:ForStatement, [:for | args]} | rest_args], context, _, _) do
    {rest, [parse(args) | rest_args], context}
  end

  def parse([:LPAREN | rest]), do: parse_iteration(%__MODULE__{}, rest)

  defp parse_iteration(for_struct, [:COMMA | rest]) do
    parse_iteration(for_struct, rest)
  end

  defp parse_iteration(for_struct, [:RPAREN, :| | rest]) do
    for_struct
    |> Map.update!(:iterators, &Enum.reverse/1)
    |> parse_capture(rest)
  end

  defp parse_iteration(for_struct, [item, :DOT2, item2 | rest])
       when item2 in [:RPAREN, :COMMA] do
    for_struct
    |> Map.update!(:iterators, &[{:.., item} | &1])
    |> parse_iteration([item2 | rest])
  end

  defp parse_iteration(for_struct, [item, :DOT2, item2 | rest]) do
    for_struct
    |> Map.update!(:iterators, &[{:.., item, item2} | &1])
    |> parse_iteration(rest)
  end

  defp parse_iteration(for_struct, [item | rest]) do
    for_struct
    |> Map.update!(:iterators, &[item | &1])
    |> parse_iteration(rest)
  end

  defp parse_capture(for_struct, [:COMMA | rest]) do
    parse_capture(for_struct, rest)
  end

  defp parse_capture(for_struct, [:|, block | rest]) do
    for_struct
    |> Map.update!(:captures, &Enum.reverse/1)
    |> Map.replace!(:block, block)
    |> parse_else(rest)
  end

  defp parse_capture(for_struct, [:*, capture | rest]) do
    for_struct
    |> Map.update!(:captures, &[{:*, capture} | &1])
    |> parse_capture(rest)
  end

  defp parse_capture(for_struct, [capture | rest]) do
    for_struct
    |> Map.update!(:captures, &[capture | &1])
    |> parse_capture(rest)
  end

  defp parse_else(for_struct, terminator) when terminator in @terminators, do: for_struct

  defp parse_else(for_struct, [:else, block | terminator]) when terminator in @terminators do
    Map.replace!(for_struct, :else, block)
  end
end
