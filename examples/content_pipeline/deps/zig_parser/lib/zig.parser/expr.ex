defmodule Zig.Parser.Expr do
  def post_traverse(rest, [{:Expr, args} | rest_args], context, _, _) do
    {tree, []} = parse(:term, args, [], [])
    {rest, [tree | rest_args], context}
  end

  # implements the shunting yard algorithm to get correct pairing of operators.

  @prefix_operators ~w[! - ~ -% & try]a

  @infix_operators ~w[
    * / % ** *% *| ||
    + - ++ +% -% +| -|
    << >> <<|
    & ^ | orelse catch
    == != < > <= >= and or]a

  @operator_order @infix_operators
                  |> Enum.with_index()
                  |> Map.new()

  defp parse(:term, [prefix | _] = input, operators, output) when prefix in @prefix_operators do
    {result, rest} = slurp_prefix(input)
    parse(:operator, rest, operators, [result | output])
  end

  defp parse(:term, [term | rest], operators, output) do
    parse(:operator, rest, operators, [term | output])
  end

  defp parse(:operator, [infix | _] = input, [top | _] = operators, output)
       when infix in @infix_operators do
    {to_push, in_rest} = process_operator(input)

    if precedence(top) < precedence(infix) do
      # when the top has earlier precedence, send the operator stack to the output, then
      # parse the rest of the input.
      parse(:term, in_rest, [to_push], Enum.reverse(operators, output))
    else
      # when the bottom has earlier precedence, just put the new operator on top.
      parse(:term, in_rest, [to_push | operators], output)
    end
  end

  # when the input is empty, process the operators as rpn.
  defp parse(:operator, [], operators, output) do
    operators
    |> Enum.reverse(output)
    |> reverse_tree()
  end

  # if there are no operators, just push it into the operators stack
  defp parse(:operator, [head | _] = input, [], output) when head in @infix_operators do
    {to_push, in_rest} = process_operator(input)

    parse(:term, in_rest, [to_push], output)
  end

  defp slurp_prefix([prefix | rest]) when prefix in @prefix_operators do
    {term, prefix_rest} = slurp_prefix(rest)
    {{prefix, term}, prefix_rest}
  end

  defp slurp_prefix([term | rest]), do: {term, rest}

  defp precedence({:catch, _}), do: Map.fetch!(@operator_order, :catch)
  defp precedence(op), do: Map.fetch!(@operator_order, op)

  defp process_operator([:catch, :|, capture, :| | rest]) do
    {{:catch, capture}, rest}
  end

  defp process_operator([operator | rest]), do: {operator, rest}

  defp reverse_tree([operator | rest]) when operator in @infix_operators do
    {right, remainder1} = reverse_tree(rest)
    {left, remainder2} = reverse_tree(remainder1)
    {{operator, left, right}, remainder2}
  end

  defp reverse_tree([{:catch, capture} | rest]) do
    {right, remainder1} = reverse_tree(rest)
    {left, remainder2} = reverse_tree(remainder1)
    {{:catch, left, capture, right}, remainder2}
  end

  defp reverse_tree([term | rest]), do: {term, rest}
end
