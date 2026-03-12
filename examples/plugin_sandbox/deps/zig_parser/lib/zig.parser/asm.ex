defmodule Zig.Parser.Asm do
  alias Zig.Parser

  defstruct [:location, :code, outputs: [], inputs: [], clobbers: [], volatile: false]

  def post_traverse(rest, [{:AsmExpr, [start, :asm | args]} | args_rest], context, _, _) do
    asm =
      args
      |> parse(%__MODULE__{})
      |> Parser.put_location(start)

    {rest, [asm | args_rest], context}
  end

  defp parse([:volatile | rest], asm) do
    parse_code(rest, %{asm | volatile: true})
  end

  defp parse(rest, asm), do: parse_code(rest, asm)

  defp parse_code([:LPAREN, code | rest], asm) do
    next_asm = %{asm | code: code}

    case rest do
      [:COLON | more] ->
        parse_rest(more, next_asm)

      [:RPAREN] ->
        next_asm
    end
  end

  defp parse_rest([{:AsmOutputList, outputs} | rest], asm) do
    next_asm = %{asm | outputs: parse_io(outputs, [])}

    case rest do
      [:COLON | more] ->
        parse_rest(more, next_asm)

      [:RPAREN] ->
        next_asm
    end
  end

  defp parse_rest([{:AsmInputList, inputs} | rest], asm) do
    next_asm = %{asm | inputs: parse_io(inputs, [])}

    case rest do
      [:COLON | more] ->
        parse_rest(more, next_asm)

      [:RPAREN] ->
        next_asm
    end
  end

  defp parse_rest([clobbers, :RPAREN], asm) do
    %{asm | clobbers: clobbers}
  end

  defp parse_io(
         [
           :LBRACKET,
           id,
           :RBRACKET,
           {:string, assign},
           :LPAREN,
           :MINUSRARROW,
           type,
           :RPAREN | rest
         ],
         so_far
       ) do
    parse_io(rest, [{id, assign, type: type} | so_far])
  end

  defp parse_io(
         [:LBRACKET, id, :RBRACKET, {:string, assign}, :LPAREN, identifier, :RPAREN | rest],
         so_far
       ) do
    parse_io(rest, [{id, assign, var: identifier} | so_far])
  end

  defp parse_io([:COMMA | rest], so_far) do
    parse_io(rest, so_far)
  end

  defp parse_io([], so_far), do: Enum.reverse(so_far)
end
