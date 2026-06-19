defmodule QuickBEAM.JS.Parser.Validation.PrivateNames do
  @moduledoc "Class private-name validation."

  alias QuickBEAM.JS.Parser.AST
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]

  def validate_duplicate_private_names(state, body) do
    if Enum.any?(body, &duplicate_private_names_statement?/1) do
      add_error(state, current(state), "duplicate private name")
    else
      state
    end
  end

  defp duplicate_private_names_statement?(%AST.ClassDeclaration{body: body}),
    do: duplicate_private_names?(body)

  defp duplicate_private_names_statement?(%AST.ExpressionStatement{expression: expression}),
    do: duplicate_private_names_expression?(expression)

  defp duplicate_private_names_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &duplicate_private_names_expression?(&1.init))
  end

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

  defp private_element_signature(%AST.FieldDefinition{
         key: %AST.PrivateIdentifier{name: name},
         static: static?
       }),
       do: {name, {:field, static?}}

  defp private_element_signature(%AST.MethodDefinition{
         key: %AST.PrivateIdentifier{name: name},
         kind: kind,
         static: static?
       }),
       do: {name, {kind, static?}}

  defp private_element_signature(_element), do: nil

  defp duplicate_private_kind?(kinds, {:get, static?}) do
    MapSet.member?(kinds, {:get, static?}) or
      MapSet.difference(kinds, MapSet.new([{:set, static?}])) != MapSet.new()
  end

  defp duplicate_private_kind?(kinds, {:set, static?}) do
    MapSet.member?(kinds, {:set, static?}) or
      MapSet.difference(kinds, MapSet.new([{:get, static?}])) != MapSet.new()
  end

  defp duplicate_private_kind?(kinds, _kind), do: MapSet.size(kinds) > 0

  defp duplicate_private_names_expression?(%AST.ClassExpression{body: body}),
    do: duplicate_private_names?(body)

  defp duplicate_private_names_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: duplicate_private_names_expression?(left) or duplicate_private_names_expression?(right)

  defp duplicate_private_names_expression?(_expression), do: false

  def validate_declared_private_names(state, body) do
    if Enum.any?(body, &undeclared_private_names_statement?/1) do
      add_error(state, current(state), "undeclared private name")
    else
      state
    end
  end

  defp undeclared_private_names_statement?(%AST.ClassDeclaration{
         super_class: super_class,
         body: body
       }) do
    declared = MapSet.new()

    undeclared_private_expression?(super_class, declared) or
      undeclared_private_names?(body, declared)
  end

  defp undeclared_private_names_statement?(statement),
    do: undeclared_private_statement?(statement, MapSet.new())

  defp declared_private_names(%AST.FieldDefinition{key: %AST.PrivateIdentifier{name: name}}),
    do: [name]

  defp declared_private_names(%AST.MethodDefinition{key: %AST.PrivateIdentifier{name: name}}),
    do: [name]

  defp declared_private_names(_element), do: []

  defp undeclared_private_names?(body, inherited_declared) do
    declared =
      body
      |> Enum.flat_map(&declared_private_names/1)
      |> MapSet.new()
      |> MapSet.union(inherited_declared)

    Enum.any?(body, &uses_undeclared_private_name?(&1, declared))
  end

  defp uses_undeclared_private_name?(
         %AST.FieldDefinition{key: key, value: value, computed: true},
         declared
       ),
       do:
         undeclared_private_expression?(key, declared) or
           undeclared_private_expression?(value, declared)

  defp uses_undeclared_private_name?(%AST.FieldDefinition{value: value}, declared),
    do: undeclared_private_expression?(value, declared)

  defp uses_undeclared_private_name?(
         %AST.MethodDefinition{key: key, value: value, computed: true},
         declared
       ),
       do:
         undeclared_private_expression?(key, declared) or
           undeclared_private_statement?(value.body, declared)

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

  defp undeclared_private_statement?(%AST.FunctionDeclaration{body: body}, declared),
    do: undeclared_private_statement?(body, declared)

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
         %AST.ClassExpression{super_class: super_class, body: body},
         declared
       ),
       do:
         undeclared_private_expression?(super_class, declared) or
           undeclared_private_names?(body, declared)

  defp undeclared_private_expression?(%AST.FunctionExpression{body: body}, declared),
    do: undeclared_private_statement?(body, declared)

  defp undeclared_private_expression?(
         %AST.ArrowFunctionExpression{body: %AST.BlockStatement{} = body},
         declared
       ),
       do: undeclared_private_statement?(body, declared)

  defp undeclared_private_expression?(%AST.ArrowFunctionExpression{body: body}, declared),
    do: undeclared_private_expression?(body, declared)

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

  def validate_private_delete(state, body) do
    if Enum.any?(body, &private_delete_statement?/1) do
      add_error(state, current(state), "cannot delete a private class field")
    else
      state
    end
  end

  defp private_delete_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &private_delete_statement?/1)

  defp private_delete_statement?(%AST.ClassDeclaration{body: body}),
    do: Enum.any?(body, &private_delete_class_element?/1)

  defp private_delete_statement?(%AST.ExpressionStatement{expression: expression}),
    do: private_delete_expression?(expression)

  defp private_delete_statement?(%AST.ReturnStatement{argument: argument}),
    do: private_delete_expression?(argument)

  defp private_delete_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &private_delete_expression?(&1.init))
  end

  defp private_delete_statement?(_statement), do: false

  defp private_delete_class_element?(%AST.FieldDefinition{value: value}),
    do: private_delete_expression?(value)

  defp private_delete_class_element?(%AST.MethodDefinition{value: value}),
    do: private_delete_statement?(value.body)

  defp private_delete_class_element?(%AST.StaticBlock{body: body}),
    do: Enum.any?(body, &private_delete_statement?/1)

  defp private_delete_class_element?(_element), do: false

  defp private_delete_expression?(nil), do: false

  defp private_delete_expression?(%AST.ClassExpression{body: body}),
    do: Enum.any?(body, &private_delete_class_element?/1)

  defp private_delete_expression?(%AST.UnaryExpression{operator: "delete", argument: argument}),
    do: private_member_reference?(argument)

  defp private_delete_expression?(%AST.UnaryExpression{argument: argument}),
    do: private_delete_expression?(argument)

  defp private_delete_expression?(%AST.MemberExpression{object: object, property: property}),
    do: private_delete_expression?(object) or private_delete_expression?(property)

  defp private_delete_expression?(%AST.CallExpression{callee: callee, arguments: arguments}),
    do: private_delete_expression?(callee) or Enum.any?(arguments, &private_delete_expression?/1)

  defp private_delete_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: private_delete_expression?(left) or private_delete_expression?(right)

  defp private_delete_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &private_delete_expression?/1)

  defp private_delete_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &private_delete_expression?/1)

  defp private_delete_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &private_delete_expression?/1)

  defp private_delete_expression?(%AST.Property{key: key, value: value, computed: computed?}) do
    private_delete_expression?(value) or (computed? and private_delete_expression?(key))
  end

  defp private_delete_expression?(%AST.ConditionalExpression{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    private_delete_expression?(test) or private_delete_expression?(consequent) or
      private_delete_expression?(alternate)
  end

  defp private_delete_expression?(%AST.ArrowFunctionExpression{
         body: %AST.BlockStatement{} = body
       }),
       do: private_delete_statement?(body)

  defp private_delete_expression?(%AST.ArrowFunctionExpression{body: body}),
    do: private_delete_expression?(body)

  defp private_delete_expression?(_expression), do: false

  def validate_private_super_access(state, body) do
    if Enum.any?(body, &private_super_access_statement?/1) do
      add_error(state, current(state), "private class field forbidden after super")
    else
      state
    end
  end

  defp private_super_access_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &private_super_access_statement?/1)

  defp private_super_access_statement?(%AST.ClassDeclaration{
         super_class: super_class,
         body: body
       }),
       do:
         private_super_access_expression?(super_class) or
           Enum.any?(body, &private_super_access_class_element?/1)

  defp private_super_access_statement?(%AST.ExpressionStatement{expression: expression}),
    do: private_super_access_expression?(expression)

  defp private_super_access_statement?(%AST.ReturnStatement{argument: argument}),
    do: private_super_access_expression?(argument)

  defp private_super_access_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &private_super_access_expression?(&1.init))
  end

  defp private_super_access_statement?(_statement), do: false

  defp private_super_access_class_element?(%AST.FieldDefinition{
         key: key,
         value: value,
         computed: computed?
       }) do
    (computed? and private_super_access_expression?(key)) or
      private_super_access_expression?(value)
  end

  defp private_super_access_class_element?(%AST.MethodDefinition{
         key: key,
         value: value,
         computed: computed?
       }) do
    (computed? and private_super_access_expression?(key)) or
      private_super_access_statement?(value.body)
  end

  defp private_super_access_class_element?(%AST.StaticBlock{body: body}),
    do: Enum.any?(body, &private_super_access_statement?/1)

  defp private_super_access_class_element?(_element), do: false

  defp private_super_access_expression?(nil), do: false

  defp private_super_access_expression?(%AST.MemberExpression{
         object: %AST.Identifier{name: "super"},
         property: %AST.PrivateIdentifier{}
       }),
       do: true

  defp private_super_access_expression?(%AST.ClassExpression{
         super_class: super_class,
         body: body
       }),
       do:
         private_super_access_expression?(super_class) or
           Enum.any?(body, &private_super_access_class_element?/1)

  defp private_super_access_expression?(%AST.MemberExpression{
         object: object,
         property: property
       }),
       do: private_super_access_expression?(object) or private_super_access_expression?(property)

  defp private_super_access_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }),
       do:
         private_super_access_expression?(callee) or
           Enum.any?(arguments, &private_super_access_expression?/1)

  defp private_super_access_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: private_super_access_expression?(left) or private_super_access_expression?(right)

  defp private_super_access_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &private_super_access_expression?/1)

  defp private_super_access_expression?(_expression), do: false

  defp private_member_reference?(%AST.MemberExpression{property: %AST.PrivateIdentifier{}}),
    do: true

  defp private_member_reference?(%AST.CallExpression{callee: callee}),
    do: private_member_reference?(callee)

  defp private_member_reference?(_expression), do: false

  def validate_private_in_expressions(state, body) do
    if Enum.any?(body, &invalid_private_in_statement?/1) do
      add_error(state, current(state), "invalid private in expression")
    else
      state
    end
  end

  defp invalid_private_in_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &invalid_private_in_statement?/1)

  defp invalid_private_in_statement?(%AST.ClassDeclaration{body: body}),
    do: Enum.any?(body, &invalid_private_in_class_element?/1)

  defp invalid_private_in_statement?(%AST.ExpressionStatement{expression: expression}),
    do: invalid_private_in_expression?(expression)

  defp invalid_private_in_statement?(%AST.ReturnStatement{argument: argument}),
    do: invalid_private_in_expression?(argument)

  defp invalid_private_in_statement?(%AST.ForInStatement{left: %AST.PrivateIdentifier{}}),
    do: true

  defp invalid_private_in_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &invalid_private_in_expression?(&1.init))
  end

  defp invalid_private_in_statement?(_statement), do: false

  defp invalid_private_in_class_element?(%AST.FieldDefinition{value: value}),
    do: invalid_private_in_expression?(value)

  defp invalid_private_in_class_element?(%AST.MethodDefinition{value: value}),
    do: invalid_private_in_statement?(value.body)

  defp invalid_private_in_class_element?(%AST.StaticBlock{body: body}),
    do: Enum.any?(body, &invalid_private_in_statement?/1)

  defp invalid_private_in_class_element?(_element), do: false

  defp invalid_private_in_expression?(%AST.BinaryExpression{
         operator: "in",
         left: %AST.PrivateIdentifier{},
         right: %AST.PrivateIdentifier{}
       }),
       do: true

  defp invalid_private_in_expression?(%AST.BinaryExpression{
         operator: "in",
         left: %AST.PrivateIdentifier{},
         right: %AST.BinaryExpression{operator: "in", left: %AST.PrivateIdentifier{}}
       }),
       do: true

  defp invalid_private_in_expression?(%AST.BinaryExpression{
         operator: "in",
         left: %AST.PrivateIdentifier{},
         right: %AST.ArrowFunctionExpression{}
       }),
       do: true

  defp invalid_private_in_expression?(%AST.BinaryExpression{
         operator: "in",
         left: %AST.PrivateIdentifier{},
         right: %AST.Identifier{name: "yield"}
       }),
       do: true

  defp invalid_private_in_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: invalid_private_in_expression?(left) or invalid_private_in_expression?(right)

  defp invalid_private_in_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: invalid_private_in_expression?(left) or invalid_private_in_expression?(right)

  defp invalid_private_in_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &invalid_private_in_expression?/1)

  defp invalid_private_in_expression?(_expression), do: false
end
