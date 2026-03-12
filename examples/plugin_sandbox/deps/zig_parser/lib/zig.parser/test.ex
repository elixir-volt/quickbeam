defmodule Zig.Parser.Test do
  alias Zig.Parser
  alias Zig.Parser.Block

  defstruct [:block, :name, :location]

  def post_traverse(
        rest,
        [{:TestDecl, [start, {:doc_comment, comment} | args]} | rest_args],
        context,
        _,
        _
      ) do
    ast =
      args
      |> parse
      |> Map.replace!(:doc_comment, comment)
      |> Parser.put_location(start)

    {rest, [ast | rest_args], context}
  end

  def post_traverse(rest, [{:TestDecl, [start | args]} | rest_args], context, _, _) do
    ast =
      args
      |> parse
      |> Parser.put_location(start)

    {rest, [ast | rest_args], context}
  end

  defp parse([:test, %Block{} = block]) do
    %__MODULE__{block: block}
  end

  defp parse([:test, {:string, name}, %Block{} = block]) do
    %__MODULE__{name: name, block: block}
  end

  defp parse([:test, name, %Block{} = block]) do
    %__MODULE__{name: name, block: block}
  end
end
