defmodule Zig.Parser.If do
  defstruct [
    :test,
    :then,
    :else,
    :ptr_payload,
    :else_payload,
    :location,
    comptime: false
  ]

  @terminators [[], [:SEMICOLON]]

  def parse(args), do: parse(args, %__MODULE__{})

  defp parse([:LPAREN, test, :RPAREN, :|, payload, :| | rest], if_struct) do
    parse_then(rest, %{if_struct | test: test, ptr_payload: payload})
  end

  defp parse([:LPAREN, test, :RPAREN, :|, :*, payload, :| | rest], if_struct) do
    parse_then(rest, %{if_struct | test: test, ptr_payload: {:*, payload}})
  end

  defp parse([:LPAREN, test, :RPAREN | rest], if_struct) do
    parse_then(rest, %{if_struct | test: test})
  end

  defp parse_then([then | terminator], if_struct) when terminator in @terminators do
    %{if_struct | then: then}
  end

  defp parse_then([then, :else | rest], if_struct) do
    parse_else(rest, %{if_struct | then: then})
  end

  defp parse_else([:|, else_payload, :|, else_expr], if_struct) do
    %{if_struct | else_payload: else_payload, else: else_expr}
  end

  defp parse_else([else_expr | terminator], if_struct) when terminator in @terminators do
    %{if_struct | else: else_expr}
  end
end
