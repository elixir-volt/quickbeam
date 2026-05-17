defmodule QuickBEAM.JS.Compiler.Declarations do
  @moduledoc false

  alias QuickBEAM.JS.Compiler.Scope
  alias QuickBEAM.JS.Parser.AST

  def declare_program_locals(statements, scope), do: declare_statements(statements, scope)

  defp declare_statements([], scope), do: {:ok, scope}

  defp declare_statements(
         [%AST.VariableDeclaration{kind: kind, declarations: declarations} | rest],
         scope
       ) do
    scope =
      Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc, kind) end)

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
    scope =
      Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc, :var) end)

    scope = declare_nested_var_bindings_from(scope, body)
    declare_statements(rest, scope)
  end

  defp declare_statements(
         [
           %AST.ForOfStatement{
             left: %AST.VariableDeclaration{kind: kind, declarations: declarations}
           }
           | rest
         ],
         scope
       ) do
    scope =
      Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc, kind) end)

    scope = Scope.declare_local(scope, "<for_of_array>")
    scope = Scope.declare_local(scope, "<for_of_index>")
    scope = Scope.declare_local(scope, "<for_of_value>")
    declare_statements(rest, scope)
  end

  defp declare_statements(
         [
           %AST.ForInStatement{
             left: %AST.VariableDeclaration{kind: kind, declarations: declarations}
           }
           | rest
         ],
         scope
       ) do
    scope =
      Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc, kind) end)

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

  defp declare_nested_var_bindings(%AST.BlockStatement{body: body}, scope) do
    {scope, descriptor} = declare_block_lexical_bindings(body, scope)
    register_block_scope(descriptor)
    declare_var_statements(body, scope)
  end

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
    |> Enum.reduce(scope, fn %{id: id}, acc -> declare_pattern(id, acc, :var) end)
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
    scope =
      Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc, :var) end)

    declare_var_statements(rest, scope)
  end

  defp declare_var_statements([statement | rest], scope) do
    scope = declare_nested_var_bindings(statement, scope)
    declare_var_statements(rest, scope)
  end

  defp declare_pattern(%AST.Identifier{name: name}, scope, kind),
    do: Scope.declare_local(scope, name, kind)

  defp declare_pattern(%AST.ObjectPattern{properties: properties}, scope, kind) do
    scope =
      Enum.reduce(properties, scope, fn
        %AST.Property{value: value}, acc -> declare_pattern(value, acc, kind)
        %AST.RestElement{argument: argument}, acc -> declare_pattern(argument, acc, kind)
        _property, acc -> acc
      end)

    properties
    |> object_rest_computed_key_temps()
    |> Enum.reduce(scope, &Scope.declare_local(&2, &1))
  end

  defp declare_pattern(%AST.ArrayPattern{elements: elements}, scope, kind) do
    elements
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(scope, &declare_pattern(&1, &2, kind))
  end

  defp declare_pattern(%AST.AssignmentPattern{left: left}, scope, kind) do
    declare_pattern(left, scope, kind)
  end

  defp declare_pattern(%AST.RestElement{argument: argument}, scope, kind) do
    declare_pattern(argument, scope, kind)
  end

  defp declare_pattern(_pattern, scope, _kind), do: scope

  defp declare_block_lexical_bindings(body, scope) do
    block_id = next_block_scope_id()

    {scope, bindings} =
      body
      |> Enum.flat_map(&block_lexical_declarations/1)
      |> Enum.reduce({scope, []}, fn {name, kind}, {acc_scope, bindings} ->
        hidden_name = hidden_block_local_name(block_id, length(bindings), name)
        acc_scope = Scope.declare_local(acc_scope, hidden_name, kind)
        {acc_scope, [{name, hidden_name, kind} | bindings]}
      end)

    {scope, %{id: block_id, bindings: Enum.reverse(bindings)}}
  end

  defp block_lexical_declarations(%AST.VariableDeclaration{
         kind: kind,
         declarations: declarations
       })
       when kind in [:let, :const] do
    declarations
    |> Enum.flat_map(fn %{id: id} -> pattern_binding_names(id) end)
    |> Enum.map(&{&1, kind})
  end

  defp block_lexical_declarations(_statement), do: []

  defp pattern_binding_names(%AST.Identifier{name: name}), do: [name]

  defp pattern_binding_names(%AST.ObjectPattern{properties: properties}) do
    Enum.flat_map(properties, fn
      %AST.Property{value: value} -> pattern_binding_names(value)
      %AST.RestElement{argument: argument} -> pattern_binding_names(argument)
      _property -> []
    end)
  end

  defp pattern_binding_names(%AST.ArrayPattern{elements: elements}) do
    elements
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&pattern_binding_names/1)
  end

  defp pattern_binding_names(%AST.AssignmentPattern{left: left}), do: pattern_binding_names(left)

  defp pattern_binding_names(%AST.RestElement{argument: argument}),
    do: pattern_binding_names(argument)

  defp pattern_binding_names(_pattern), do: []

  defp next_block_scope_id do
    id = Process.get(:compiler_block_scope_declaration_id, 0)
    Process.put(:compiler_block_scope_declaration_id, id + 1)
    id
  end

  defp hidden_block_local_name(block_id, index, name),
    do: "<block:#{block_id}:#{index}:#{name}>"

  defp register_block_scope(%{bindings: []}), do: :ok

  defp register_block_scope(descriptor) do
    scopes = Process.get(:compiler_block_scopes, [])
    Process.put(:compiler_block_scopes, scopes ++ [descriptor])
  end

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
