defmodule Zig.Parser.TypeExpr do
  @literals Zig.Parser.Collected.literals()

  alias Zig.Parser.Array
  alias Zig.Parser.Pointer

  def post_traverse(rest, [{:TypeExpr, args} | rest_args], context, _, _) do
    {rest, [parse(args) | rest_args], context}
  end

  defp parse([literalterm = {literal, _}]) when literal in @literals, do: literalterm
  defp parse([:DOT, enum]), do: {:enumliteral, enum}

  @pointer_next ~w[RBRACKET * COLON]a

  defp parse([{:PrefixTypeOp, [:LBRACKET, next | _] = prefix} | rest])
       when next in @pointer_next do
    Pointer.parse(prefix, parse(rest))
  end

  defp parse([{:PrefixTypeOp, [:LBRACKET | _] = array} | rest]) do
    Array.parse(array, parse(rest))
  end

  defp parse([{:PrefixTypeOp, [:* | _] = pointer} | rest]) do
    Pointer.parse(pointer, parse(rest))
  end

  defp parse([{:PrefixTypeOp, [:** | prefix_rest]} | rest]) do
    parse([{:PrefixTypeOp, [:*]}, {:PrefixTypeOp, [:* | prefix_rest]} | rest])
  end

  defp parse([{:PrefixTypeOp, [:anyframe, :MINUSRARROW]} | rest]), do: {:anyframe, parse(rest)}

  defp parse([{:PrefixTypeOp, [:QUESTIONMARK]} | rest]), do: {:optional, parse(rest)}

  defp parse([singleton]), do: singleton
end
