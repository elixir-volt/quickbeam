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
      {:ok, %AST.Program{body: body}} ->
        body
        |> Enum.flat_map(&simple_assigned_names_from_statement/1)
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

  defp simple_assigned_names_from_statement(%AST.ExpressionStatement{
         expression: %AST.AssignmentExpression{left: %AST.Identifier{name: name}}
       }),
       do: [name]

  defp simple_assigned_names_from_statement(_), do: []
end
