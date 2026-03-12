defmodule Zig.Parser.PrimaryExpr do
  alias Zig.Parser
  alias Zig.Parser.For
  alias Zig.Parser.If
  alias Zig.Parser.StructLiteral
  alias Zig.Parser.While
  alias Zig.Parser.Switch

  def post_traverse(rest, [{:PrimaryExpr, [start | args]} | args_rest], context, _, _) do
    expr =
      case parse(args) do
        struct_value when is_struct(struct_value) -> Parser.put_location(struct_value, start)
        tuple_value when is_tuple(tuple_value) -> tuple_value
        atom_value when is_atom(atom_value) -> atom_value
      end

    {rest, [expr | args_rest], context}
  end

  defp parse([:comptime | rest]) do
    case parse(rest) do
      result = %{comptime: _} -> %{result | comptime: true}
      expr -> {:comptime, expr}
    end
  end

  defp parse([:if | rest]), do: If.parse(rest)
  defp parse([:for | rest]), do: For.parse(rest)
  defp parse([:while | rest]), do: While.parse(rest)
  defp parse([:switch | rest]), do: Switch.parse(rest)

  defp parse([:break]), do: :break
  defp parse([:break, :COLON, tag]), do: {:break, tag}
  defp parse([:break, :COLON, tag, expr]), do: {:break, tag, expr}
  defp parse([:break, expr]), do: {:break, :_, expr}

  defp parse([:continue]), do: :continue
  defp parse([:continue, :COLON, tag]), do: {:continue, tag}
  defp parse([:continue, :COLON, tag, expr]), do: {:continue, tag, expr}

  defp parse([:nosuspend, expr]), do: {:nosuspend, expr}
  defp parse([:resume, expr]), do: {:resume, expr}

  defp parse([:return]), do: :return
  defp parse([:return, expr]), do: {:return, expr}

  defp parse([:inline | rest]) do
    %{parse(rest) | inline: true}
  end

  defp parse([label, :COLON | rest]) do
    %{parse(rest) | label: label}
  end

  defp parse([identifier, map]) when is_map(map) do
    %StructLiteral{type: identifier, values: map}
  end

  defp parse([identifier, list]) when is_list(list) do
    array =
      list
      |> Enum.with_index()
      |> Map.new(fn {item, index} -> {index, item} end)

    %StructLiteral{type: identifier, values: array}
  end

  defp parse([arg]), do: arg
end
