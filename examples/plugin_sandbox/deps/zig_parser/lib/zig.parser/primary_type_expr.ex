defmodule Zig.Parser.PrimaryTypeExpr do
  alias Zig.Parser.ErrorSet
  alias Zig.Parser.Function
  alias Zig.Parser.If
  alias Zig.Parser.StructLiteral
  alias Zig.Parser.Switch

  def post_traverse(rest, [{:PrimaryTypeExpr, args} | args_rest], context, _, _) do
    expr = parse(args)

    # modify the context to add dependencies if we have either embedFile or import
    # builtins.

    new_context =
      case expr do
        {:call, :embedFile, [string: path]} ->
          %{context | dependencies: context.dependencies ++ [path]}

        {:call, :import, [string: path]} ->
          if Path.extname(path) == ".zig" do
            %{context | dependencies: context.dependencies ++ [path]}
          else
            context
          end

        _ ->
          context
      end

    {rest, [expr | args_rest], new_context}
  end

  def _parse(a), do: parse(a)

  defp parse([{:builtin, name}, :LPAREN, {:ExprList, args}, :RPAREN]) do
    {:call, name, Zig.Parser._parse_args(args, [])}
  end

  defp parse([:DOT, map]) when is_map(map) do
    %StructLiteral{values: map}
  end

  defp parse([:DOT, list]) when is_list(list) do
    map =
      list
      |> Enum.with_index()
      |> Map.new(fn {value, index} -> {index, value} end)

    %StructLiteral{values: map}
  end

  defp parse([:DOT, {:empty}]), do: {:empty}

  defp parse([:DOT, enum_literal]) do
    {:enum_literal, enum_literal}
  end

  defp parse([:comptime | rest]) do
    {:comptime, parse(rest)}
  end

  defp parse(["'", parsed_char, "'"]), do: parsed_char

  # error sets and error literals

  defp parse([:error, :LBRACE | errorset]), do: ErrorSet.parse([:LBRACE | errorset])

  defp parse([:error, :DOT, error]), do: {:error, error}

  # FnProto
  defp parse(fnproto = [:fn | _rest]), do: Function.parse(fnproto)

  # GroupedExpr
  defp parse([:LPAREN, expr, :RPAREN]), do: expr

  # LabeledExpr
  defp parse([label, :COLON, %{} = expr]) do
    %{expr | label: label}
  end

  # IfExpr
  defp parse([:if | ifexpr]), do: If.parse(ifexpr)

  # SwitchExpr
  defp parse([:switch | switch]), do: Switch.parse(switch)

  defp parse([any]), do: any
end
