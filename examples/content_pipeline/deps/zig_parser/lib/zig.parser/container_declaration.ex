defmodule Zig.Parser.ContainerDeclaration do
  def post_traverse(rest, [{:ContainerDeclaration, []} | rest_args], context, _loc, _row) do
    {rest, rest_args, context}
  end

  def post_traverse(rest, [{:ContainerDeclaration, args} | rest_args], context, _loc, _row) do
    new_args =
      args
      |> parse(nil, [])
      |> Enum.reverse(rest_args)

    {rest, new_args, context}
  end

  defp parse([:comptime | rest], attrs, so_far) do
    new_attrs =
      attrs
      |> List.wrap()
      |> Keyword.put(:comptime, true)

    parse(rest, new_attrs, so_far)
  end

  defp parse([{:doc_comment, comment} | rest], attrs, so_far) do
    new_attrs =
      attrs
      |> List.wrap()
      |> Keyword.put(:doc_comment, comment)

    parse(rest, new_attrs, so_far)
  end

  defp parse([:pub | rest], attrs, so_far) do
    new_attrs =
      attrs
      |> List.wrap()
      |> Keyword.put(:pub, true)

    parse(rest, new_attrs, so_far)
  end

  defp parse([term | rest], nil, so_far) do
    parse(rest, nil, [term | so_far])
  end

  defp parse([term | rest], attrs, so_far) do
    parse(rest, nil, [struct!(term, attrs) | so_far])
  end

  defp parse([], _, so_far), do: Enum.reverse(so_far)
end
