defmodule QuickBEAM.VM.Semantics.Eval do
  @moduledoc "Shared helpers for direct-eval semantics across interpreter and compiler paths."

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.VM.{EvalLexical, Names}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.JSThrow

  def simple_delete_identifier(code, globals) when is_map(globals) do
    case Parser.parse(code) do
      {:ok,
       %AST.Program{
         body: [
           %AST.ExpressionStatement{
             expression: %AST.UnaryExpression{
               operator: "delete",
               argument: %AST.Identifier{name: name}
             }
           }
         ]
       }} ->
        {:ok, not Map.has_key?(globals, name)}

      _ ->
        :error
    end
  end

  def simple_assigned_names(code) do
    case Parser.parse(code) do
      {:ok, %AST.Program{} = program} ->
        program
        |> assigned_names_from_node([])
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  def declared_local_names(%QuickBEAM.VM.Function{locals: locals}) do
    locals
    |> Enum.map(&Names.resolve_display_name(&1.name))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  def declared_local_names(_), do: MapSet.new()

  def lexical_conflict?(%Context{} = ctx, declared_names) do
    ctx
    |> EvalLexical.current_lexical_names()
    |> MapSet.disjoint?(declared_names)
    |> Kernel.not()
  end

  def lexical_conflict?(_ctx, _declared_names), do: false

  def reject_lexical_conflicts!(ctx, declared_names, strict?) do
    if not strict? and lexical_conflict?(ctx, declared_names) do
      JSThrow.syntax_error!("Identifier has already been declared")
    end
  end

  def reject_class_field_initializer_eval!(ctx, code) when is_binary(code) do
    if class_field_initializer_context?(ctx) and initializer_eval_forbidden_syntax?(code) do
      JSThrow.syntax_error!("Invalid direct eval in class field initializer")
    end
  end

  def reject_class_field_initializer_eval!(_ctx, _code), do: :ok

  def normalize_class_field_initializer_eval_code(ctx, code) when is_binary(code) do
    if class_field_initializer_context?(ctx) do
      code
      |> String.replace(~r/\bnew\s*\.\s*target\b/, "undefined")
      |> String.replace(~r/\bsuper\s*(\[[^\]]+\]|\.[A-Za-z_$][\w$]*)/, "undefined")
    else
      code
    end
  end

  def normalize_class_field_initializer_eval_code(_ctx, code), do: code

  defp class_field_initializer_context?(%{current_func: current_func}) do
    case current_func do
      {:closure, captured, %QuickBEAM.VM.Function{} = fun} ->
        Map.get(captured, :__class_field_initializer__, false) or
          synthetic_field_initializer?(fun)

      %QuickBEAM.VM.Function{} = fun ->
        synthetic_field_initializer?(fun)

      _ ->
        false
    end
  end

  defp class_field_initializer_context?(_), do: false

  defp synthetic_field_initializer?(%QuickBEAM.VM.Function{source: "", locals: locals}) do
    local_names = MapSet.new(Enum.map(locals, &Names.resolve_display_name(&1.name)))
    MapSet.subset?(MapSet.new(["this", "new.target", "<home_object>"]), local_names)
  end

  defp synthetic_field_initializer?(_), do: false

  defp initializer_eval_forbidden_syntax?(code) do
    case Parser.parse(code) do
      {:ok, program} -> forbidden_initializer_node?(program)
      {:error, program, _errors} -> forbidden_initializer_node?(program)
      _ -> false
    end
  end

  defp forbidden_initializer_node?(%AST.Identifier{name: "arguments"}), do: true

  defp forbidden_initializer_node?(%AST.CallExpression{callee: %AST.Identifier{name: "super"}}),
    do: true

  defp forbidden_initializer_node?(%_{} = node) do
    node
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&forbidden_initializer_node?/1)
  end

  defp forbidden_initializer_node?(list) when is_list(list),
    do: Enum.any?(list, &forbidden_initializer_node?/1)

  defp forbidden_initializer_node?(_), do: false

  defp assigned_names_from_node(
         %AST.AssignmentExpression{left: %AST.Identifier{name: name}} = node,
         acc
       ) do
    node
    |> Map.from_struct()
    |> Map.delete(:left)
    |> assigned_names_from_map([name | acc])
  end

  defp assigned_names_from_node(%_{} = node, acc),
    do: node |> Map.from_struct() |> assigned_names_from_map(acc)

  defp assigned_names_from_node(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &assigned_names_from_node/2)

  defp assigned_names_from_node(_, acc), do: acc

  defp assigned_names_from_map(map, acc),
    do: map |> Map.values() |> Enum.reduce(acc, &assigned_names_from_node/2)
end
