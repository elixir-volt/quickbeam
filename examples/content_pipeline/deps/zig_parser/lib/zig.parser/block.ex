defmodule Zig.Parser.Block do
  @enforce_keys [:code]
  defstruct @enforce_keys ++
              [:label, :location, comptime: false, nosuspend: false, suspend: false]

  @type t :: %__MODULE__{
          label: atom,
          location: {pos_integer, pos_integer},
          code: [term],
          comptime: boolean
        }

  alias Zig.Parser
  alias Zig.Parser.Block

  def post_traverse(rest, [{:Block, [start | code]} | rest_args], context, _, _) do
    block =
      code
      |> parse
      |> Parser.put_location(start)

    {rest, [block | rest_args], context}
  end

  def post_traverse(rest, [{:BlockExpr, [start, %Block{} = code]} | rest_args], context, _, _) do
    block = Parser.put_location(code, start)
    {rest, [block | rest_args], context}
  end

  def post_traverse(
        rest,
        [{:BlockExpr, [start, label, :COLON, %Block{} = code]} | rest_args],
        context,
        _,
        _
      ) do
    block =
      code
      |> Parser.put_location(start)
      |> Map.replace!(:label, label)

    {rest, [block | rest_args], context}
  end

  defp parse([:LBRACE | rest]), do: parse(rest, [])

  defp parse([:RBRACE], so_far), do: %__MODULE__{code: Enum.reverse(so_far)}

  defp parse([statement | rest], so_far), do: parse(rest, [statement | so_far])
end
