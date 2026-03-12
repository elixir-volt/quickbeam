defmodule Zig.Parser.Statement do
  alias Zig.Parser.Block
  alias Zig.Parser.If
  alias Zig.Parser.Switch

  def post_traverse(rest, [{:Statement, args} | rest_args], context, _, _) do
    {rest, [parse(args) | rest_args], context}
  end

  defp parse([:comptime | rest_args]) do
    case parse(rest_args) do
      %{comptime: _} = parsed -> %{parsed | comptime: true}
      parsed -> {:comptime, parsed}
    end
  end

  defp parse([:nosuspend | rest_args]) do
    case parse(rest_args) do
      %Block{} = block ->
        %{block | nosuspend: true}

      other ->
        {:nosuspend, other}
    end
  end

  defp parse([:suspend | rest_args]) do
    case parse(rest_args) do
      %Block{} = block ->
        %{block | suspend: true}

      other ->
        {:suspend, other}
    end
  end

  defp parse([:defer | rest_args]) do
    {:defer, parse(rest_args)}
  end

  defp parse([:errdefer, :|, capture, :| | rest_args]) do
    {:errdefer, capture, parse(rest_args)}
  end

  defp parse([:errdefer | rest_args]) do
    {:errdefer, parse(rest_args)}
  end

  defp parse([:if | rest_args]) do
    If.parse(rest_args)
  end

  defp parse([:switch | rest_args]) do
    Switch.parse(rest_args)
  end

  defp parse([statement, :SEMICOLON]), do: statement

  defp parse([label, :COLON, :switch | rest]) do
    %{Switch.parse(rest) | label: label}
  end

  defp parse([label, :COLON, statement]) do
    %{statement | label: label}
  end

  defp parse([content]), do: content
end
