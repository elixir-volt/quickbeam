defmodule QuickBEAM.JS.Parser.Validation.PrivateNames do
  @moduledoc "Class private-name validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_duplicate_private_names(state, body) do
    if Enum.any?(body, &duplicate_private_names_statement?/1) do
      add_error(state, current(state), "duplicate private name")
    else
      state
    end
  end

  defp duplicate_private_names_statement?(%AST.ClassDeclaration{body: body}),
    do: duplicate_private_names?(body)

  defp duplicate_private_names_statement?(_statement), do: false

  defp duplicate_private_names?(elements) do
    {_, duplicate?} =
      Enum.reduce(elements, {%{}, false}, fn element, {seen, duplicate?} ->
        case private_element_signature(element) do
          nil ->
            {seen, duplicate?}

          {name, kind} ->
            kinds = Map.get(seen, name, MapSet.new())

            {Map.put(seen, name, MapSet.put(kinds, kind)),
             duplicate? or duplicate_private_kind?(kinds, kind)}
        end
      end)

    duplicate?
  end

  defp private_element_signature(%AST.FieldDefinition{key: %AST.PrivateIdentifier{name: name}}),
    do: {name, :field}

  defp private_element_signature(%AST.MethodDefinition{
         key: %AST.PrivateIdentifier{name: name},
         kind: kind
       }),
       do: {name, kind}

  defp private_element_signature(_element), do: nil

  defp duplicate_private_kind?(kinds, :get),
    do:
      MapSet.member?(kinds, :get) or MapSet.difference(kinds, MapSet.new([:set])) != MapSet.new()

  defp duplicate_private_kind?(kinds, :set),
    do:
      MapSet.member?(kinds, :set) or MapSet.difference(kinds, MapSet.new([:get])) != MapSet.new()

  defp duplicate_private_kind?(kinds, _kind), do: MapSet.size(kinds) > 0

  def validate_declared_private_names(state, body) do
    if Enum.any?(body, &undeclared_private_names_statement?/1) do
      add_error(state, current(state), "undeclared private name")
    else
      state
    end
  end

  defp undeclared_private_names_statement?(%AST.ClassDeclaration{body: body}) do
    declared =
      body
      |> Enum.flat_map(&declared_private_names/1)
      |> MapSet.new()

    Enum.any?(body, &uses_undeclared_private_name?(&1, declared))
  end

  defp undeclared_private_names_statement?(statement),
    do: undeclared_private_statement?(statement, MapSet.new())

  defp declared_private_names(%AST.FieldDefinition{key: %AST.PrivateIdentifier{name: name}}),
    do: [name]

  defp declared_private_names(%AST.MethodDefinition{key: %AST.PrivateIdentifier{name: name}}),
    do: [name]

  defp declared_private_names(_element), do: []

  defp uses_undeclared_private_name?(%AST.FieldDefinition{value: value}, declared),
    do: undeclared_private_expression?(value, declared)

  defp uses_undeclared_private_name?(%AST.MethodDefinition{value: value}, declared),
    do: undeclared_private_statement?(value.body, declared)

  defp uses_undeclared_private_name?(%AST.StaticBlock{body: body}, declared),
    do: Enum.any?(body, &undeclared_private_statement?(&1, declared))

  defp uses_undeclared_private_name?(_element, _declared), do: false

  defp undeclared_private_statement?(%AST.BlockStatement{body: body}, declared),
    do: Enum.any?(body, &undeclared_private_statement?(&1, declared))

  defp undeclared_private_statement?(%AST.ExpressionStatement{expression: expression}, declared),
    do: undeclared_private_expression?(expression, declared)

  defp undeclared_private_statement?(%AST.ReturnStatement{argument: argument}, declared),
    do: undeclared_private_expression?(argument, declared)

  defp undeclared_private_statement?(
         %AST.VariableDeclaration{declarations: declarations},
         declared
       ) do
    Enum.any?(declarations, &undeclared_private_expression?(&1.init, declared))
  end

  defp undeclared_private_statement?(_statement, _declared), do: false

  defp undeclared_private_expression?(nil, _declared), do: false

  defp undeclared_private_expression?(%AST.PrivateIdentifier{name: name}, declared),
    do: not MapSet.member?(declared, name)

  defp undeclared_private_expression?(
         %AST.MemberExpression{object: object, property: property},
         declared
       ) do
    undeclared_private_expression?(object, declared) or
      undeclared_private_expression?(property, declared)
  end

  defp undeclared_private_expression?(%AST.BinaryExpression{left: left, right: right}, declared),
    do:
      undeclared_private_expression?(left, declared) or
        undeclared_private_expression?(right, declared)

  defp undeclared_private_expression?(
         %AST.CallExpression{callee: callee, arguments: arguments},
         declared
       ),
       do:
         undeclared_private_expression?(callee, declared) or
           Enum.any?(arguments, &undeclared_private_expression?(&1, declared))

  defp undeclared_private_expression?(
         %AST.AssignmentExpression{left: left, right: right},
         declared
       ),
       do:
         undeclared_private_expression?(left, declared) or
           undeclared_private_expression?(right, declared)

  defp undeclared_private_expression?(
         %AST.SequenceExpression{expressions: expressions},
         declared
       ),
       do: Enum.any?(expressions, &undeclared_private_expression?(&1, declared))

  defp undeclared_private_expression?(_expression, _declared), do: false

  defp current(state), do: token_at(state, state.index)

  defp token_at(%{token_count: token_count, last_token: last_token}, index)
       when index >= token_count,
       do: last_token

  defp token_at(%{tokens: tokens}, index), do: elem(tokens, index)

  defp add_error(state, %Token{} = token, message) do
    error = %Error{
      message: message,
      line: token.line,
      column: token.column,
      offset: token.start
    }

    %{state | errors: [error | state.errors]}
  end
end
