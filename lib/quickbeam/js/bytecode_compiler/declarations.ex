defmodule QuickBEAM.JS.BytecodeCompiler.Declarations do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.Scope
  alias QuickBEAM.JS.Parser.AST

  def declare_program_locals(statements, scope), do: declare_statements(statements, scope)

  defp declare_statements([], scope), do: {:ok, scope}

  defp declare_statements([%AST.VariableDeclaration{declarations: declarations} | rest], scope) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    declare_statements(rest, scope)
  end

  defp declare_statements(
         [%AST.FunctionDeclaration{id: %AST.Identifier{name: name}} | rest],
         scope
       ) do
    declare_statements(rest, Scope.declare_local(scope, name))
  end

  defp declare_statements(
         [%AST.ForStatement{init: %AST.VariableDeclaration{declarations: declarations}} | rest],
         scope
       ) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    declare_statements(rest, scope)
  end

  defp declare_statements([_statement | rest], scope), do: declare_statements(rest, scope)

  defp declare_pattern(%AST.Identifier{name: name}, scope), do: Scope.declare_local(scope, name)
  defp declare_pattern(_pattern, scope), do: scope
end
