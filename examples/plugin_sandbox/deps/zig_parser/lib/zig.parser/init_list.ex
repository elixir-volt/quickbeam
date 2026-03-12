defmodule Zig.Parser.InitList do
  def post_traverse(rest, [{:InitList, args} | rest_args], context, _, _) do
    {rest, [get_init_list(args) | rest_args], context}
  end

  defp get_init_list([:LBRACE, :RBRACE]), do: %{}

  defp get_init_list([:LBRACE, :DOT | rest]), do: get_struct([:DOT | rest], %{})

  defp get_init_list([:LBRACE | rest]), do: get_array(rest, [])

  defp get_struct([:DOT, identifier, :=, expr | rest], so_far) do
    get_struct(rest, Map.put(so_far, identifier, expr))
  end

  defp get_struct([:COMMA | rest], so_far) do
    get_struct(rest, so_far)
  end

  defp get_struct([:RBRACE], struct), do: struct

  defp get_array([:RBRACE], so_far), do: Enum.reverse(so_far)
  defp get_array([:COMMA | rest], so_far), do: get_array(rest, so_far)
  defp get_array([term | rest], so_far), do: get_array(rest, [term | so_far])
end
