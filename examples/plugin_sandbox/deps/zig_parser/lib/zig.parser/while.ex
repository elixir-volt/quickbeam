defmodule Zig.Parser.While do
  defstruct [
    :block,
    :label,
    :condition,
    :payload,
    :continue,
    :location,
    :else_payload,
    :else,
    inline: false
  ]

  @terminators [[], [:SEMICOLON]]

  def post_traverse(rest, [{:WhileStatement, [:while | args]} | rest_args], context, _, _) do
    {rest, [parse(args) | rest_args], context}
  end

  def parse([:LPAREN, condition, :RPAREN | rest]) do
    parse_payload(%__MODULE__{condition: condition}, rest)
  end

  defp parse_payload(while, [:|, payload, :| | rest]) do
    while
    |> Map.replace!(:payload, payload)
    |> parse_continue(rest)
  end

  defp parse_payload(while, [:|, :*, payload, :| | rest]) do
    while
    |> Map.replace!(:payload, {:*, payload})
    |> parse_continue(rest)
  end

  defp parse_payload(while, rest), do: parse_continue(while, rest)

  defp parse_continue(while, [:COLON, :LPAREN, continue, :RPAREN | rest]) do
    while
    |> Map.replace!(:continue, continue)
    |> parse_block(rest)
  end

  defp parse_continue(while, rest), do: parse_block(while, rest)

  defp parse_else(while, terminator) when terminator in @terminators, do: while

  defp parse_else(while, [:else, block]), do: %{while | else: block}

  defp parse_else(while, [:else, :|, payload, :|, block]) do
    %{while | else: block, else_payload: payload}
  end

  defp parse_block(while, [block | rest]) do
    while
    |> Map.replace!(:block, block)
    |> parse_else(rest)
  end
end
