defmodule QuickBEAM.JS.Compiler.Declarations do
  @moduledoc false

  alias QuickBEAM.JS.Compiler.Scope
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
         [%AST.ClassDeclaration{id: %AST.Identifier{name: name}, body: cbody} | rest],
         scope
       ) do
    scope = scope |> Scope.declare_local(name) |> Scope.declare_local("<class_proto:#{name}>")

    scope =
      cbody
      |> Enum.flat_map(fn
        %{key: %AST.PrivateIdentifier{name: pn}} -> [pn]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.reduce(scope, fn pn, acc -> Scope.declare_local(acc, "##{pn}") end)

    declare_statements(rest, scope)
  end

  defp declare_statements(
         [
           %AST.ForStatement{
             init: %AST.VariableDeclaration{declarations: declarations},
             body: body
           }
           | rest
         ],
         scope
       ) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    scope = declare_nested_var_bindings_from(scope, body)
    declare_statements(rest, scope)
  end

  defp declare_statements(
         [
           %AST.ForOfStatement{
             left: %AST.VariableDeclaration{declarations: declarations}
           }
           | rest
         ],
         scope
       ) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    scope = Scope.declare_local(scope, "<for_of_array>")
    scope = Scope.declare_local(scope, "<for_of_index>")
    scope = Scope.declare_local(scope, "<for_of_value>")
    declare_statements(rest, scope)
  end

  defp declare_statements(
         [
           %AST.ForInStatement{
             left: %AST.VariableDeclaration{declarations: declarations}
           }
           | rest
         ],
         scope
       ) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    scope = Scope.declare_local(scope, "<for_in_keys>")
    scope = Scope.declare_local(scope, "<for_in_index>")
    declare_statements(rest, scope)
  end

  defp declare_statements(
         [
           %AST.TryStatement{handler: %AST.CatchClause{param: %AST.Identifier{name: name}}}
           | rest
         ],
         scope
       ) do
    declare_statements(rest, Scope.declare_local(scope, name))
  end

  defp declare_statements([%AST.WithStatement{body: body} | rest], scope) do
    scope = Scope.declare_local(scope, "<with_obj>")
    scope = declare_nested_var_bindings(body, scope)
    declare_statements(rest, scope)
  end

  defp declare_statements([statement | rest], scope) do
    scope = declare_nested_var_bindings(statement, scope)
    declare_statements(rest, scope)
  end

  defp declare_nested_var_bindings(%AST.BlockStatement{body: body}, scope),
    do: declare_var_statements(body, scope)

  defp declare_nested_var_bindings(
         %AST.IfStatement{consequent: consequent, alternate: alternate},
         scope
       ) do
    scope
    |> declare_nested_var_bindings_from(consequent)
    |> declare_nested_var_bindings_from(alternate)
  end

  defp declare_nested_var_bindings(
         %AST.ForStatement{
           init: %AST.VariableDeclaration{declarations: declarations},
           body: body
         },
         scope
       ) do
    declarations
    |> Enum.reduce(scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    |> declare_nested_var_bindings_from(body)
  end

  defp declare_nested_var_bindings(%AST.ForStatement{body: body}, scope),
    do: declare_nested_var_bindings_from(scope, body)

  defp declare_nested_var_bindings(%AST.WhileStatement{body: body}, scope),
    do: declare_nested_var_bindings_from(scope, body)

  defp declare_nested_var_bindings(%AST.DoWhileStatement{body: body}, scope),
    do: declare_nested_var_bindings_from(scope, body)

  defp declare_nested_var_bindings(_statement, scope), do: scope

  defp declare_nested_var_bindings_from(scope, nil), do: scope

  defp declare_nested_var_bindings_from(scope, statement),
    do: declare_nested_var_bindings(statement, scope)

  defp declare_var_statements([], scope), do: scope

  defp declare_var_statements(
         [%AST.VariableDeclaration{kind: :var, declarations: declarations} | rest],
         scope
       ) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    declare_var_statements(rest, scope)
  end

  defp declare_var_statements([statement | rest], scope) do
    scope = declare_nested_var_bindings(statement, scope)
    declare_var_statements(rest, scope)
  end

  defp declare_pattern(%AST.Identifier{name: name}, scope), do: Scope.declare_local(scope, name)

  defp declare_pattern(%AST.ObjectPattern{properties: properties}, scope) do
    scope =
      Enum.reduce(properties, scope, fn
        %AST.Property{value: value}, acc -> declare_pattern(value, acc)
        %AST.RestElement{argument: argument}, acc -> declare_pattern(argument, acc)
        _property, acc -> acc
      end)

    properties
    |> object_rest_computed_key_temps()
    |> Enum.reduce(scope, &Scope.declare_local(&2, &1))
  end

  defp declare_pattern(%AST.ArrayPattern{elements: elements}, scope) do
    elements
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(scope, &declare_pattern/2)
  end

  defp declare_pattern(%AST.AssignmentPattern{left: left}, scope) do
    declare_pattern(left, scope)
  end

  defp declare_pattern(%AST.RestElement{argument: argument}, scope) do
    declare_pattern(argument, scope)
  end

  defp declare_pattern(_pattern, scope), do: scope

  defp object_rest_computed_key_temps(properties) do
    {temps, _index, _has_rest?} =
      Enum.reduce_while(properties, {[], 0, false}, fn
        %AST.RestElement{}, {temps, index, _has_rest?} ->
          {:halt, {temps, index, true}}

        %AST.Property{computed: true}, {temps, index, false} ->
          {:cont, {[object_rest_computed_key_temp(index) | temps], index + 1, false}}

        %AST.Property{}, {temps, index, false} ->
          {:cont, {temps, index + 1, false}}

        _property, acc ->
          {:cont, acc}
      end)

    Enum.reverse(temps)
  end

  defp object_rest_computed_key_temp(index), do: "<object_rest_key:#{index}>"
end
