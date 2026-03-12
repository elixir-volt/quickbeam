defmodule Zig.Parser.ErrorUnionExpr do
  def post_traverse(rest, [{:ErrorUnionExpr, args} | rest_args], context, _, _) do
    {rest, [parse(args) | rest_args], context}
  end

  defp parse([identifier]), do: identifier

  defp parse([_ | _] = args) do
    parse_grouped(args)
  end

  defp parse_grouped([ref, :DOT, next | rest]) do
    parse_grouped([group(ref, next) | rest])
  end

  defp parse_grouped([ref, :LBRACKET | rest]) do
    parse_indexed(ref, rest)
  end

  defp parse_grouped([ref, :".*" | rest]) do
    parse_grouped([group(ref, :*) | rest])
  end

  defp parse_grouped([ref, :".?" | rest]) do
    parse_grouped([group(ref, :"?") | rest])
  end

  defp parse_grouped([ref, :LPAREN, {:ExprList, args}, :RPAREN | rest]) do
    parse_grouped([{:call, ref, Zig.Parser._parse_args(args, [])} | rest])
  end

  defp parse_grouped([expr1, :!, expr2 | rest]) do
    parse_grouped([{:errorunion, expr1, expr2} | rest])
  end

  defp parse_grouped([ref]), do: ref

  defp parse_indexed(ref, [index, :RBRACKET | rest]) do
    parse_grouped([group(ref, {:index, index}) | rest])
  end

  defp parse_indexed(ref, [start, :DOT2, :RBRACKET | rest]) do
    parse_grouped([group(ref, {:range, start, :...}) | rest])
  end

  defp parse_indexed(ref, [start, :DOT2, :COLON, sentinel, :RBRACKET | rest]) do
    parse_grouped([group(ref, {:range, start, :..., sentinel}) | rest])
  end

  defp parse_indexed(ref, [start, :DOT2, stop, :RBRACKET | rest]) do
    parse_grouped([group(ref, {:range, start, stop}) | rest])
  end

  defp parse_indexed(ref, [start, :DOT2, stop, :COLON, sentinel, :RBRACKET | rest]) do
    parse_grouped([group(ref, {:range, start, stop, sentinel}) | rest])
  end

  defp group({:ref, ref_list}, new_ref), do: {:ref, ref_list ++ [new_ref]}

  defp group(identifier, new_ref), do: {:ref, [identifier, new_ref]}
end
