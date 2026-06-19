defmodule QuickBEAM.JS.Parser.Validation.Targets do
  @moduledoc "Assignment/update target and class constructor validation."

  alias QuickBEAM.JS.Parser.AST
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]

  @assignment_ops ~w[= += -= *= /= %= **= <<= >>= >>>= &= ^= |= &&= ||= ??=]
  @reserved_assignment_property_names MapSet.new(~w[
    break case catch class const continue debugger default delete do else enum export extends
    finally false for function if import in instanceof new null return super switch this throw true try typeof
    var void while with
  ])

  def validate_duplicate_constructors(state, body) do
    constructors = Enum.count(body, &match?(%AST.MethodDefinition{kind: :constructor}, &1))

    if constructors > 1 do
      add_error(state, current(state), "duplicate constructor")
    else
      state
    end
  end

  def validate_object_initializers(state, body) do
    if Enum.any?(body, &invalid_object_initializer_statement?/1) do
      add_error(state, current(state), "invalid object initializer")
    else
      state
    end
  end

  defp invalid_object_initializer_statement?(%AST.ExpressionStatement{expression: expression}),
    do: invalid_object_initializer_expression?(expression)

  defp invalid_object_initializer_statement?(%AST.IfStatement{
         test: test,
         consequent: consequent,
         alternate: alternate
       }),
       do:
         invalid_object_initializer_expression?(test) or
           invalid_object_initializer_statement?(consequent) or
           invalid_object_initializer_statement?(alternate)

  defp invalid_object_initializer_statement?(%AST.WhileStatement{test: test, body: body}),
    do:
      invalid_object_initializer_expression?(test) or invalid_object_initializer_statement?(body)

  defp invalid_object_initializer_statement?(%AST.DoWhileStatement{test: test}),
    do: invalid_object_initializer_expression?(test)

  defp invalid_object_initializer_statement?(%AST.SwitchStatement{discriminant: discriminant}),
    do: invalid_object_initializer_expression?(discriminant)

  defp invalid_object_initializer_statement?(_statement), do: false

  defp invalid_object_initializer_expression?(%AST.AssignmentExpression{right: right}),
    do: invalid_object_initializer_expression?(right)

  defp invalid_object_initializer_expression?(%AST.UnaryExpression{argument: argument}),
    do: invalid_object_initializer_expression?(argument)

  defp invalid_object_initializer_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &invalid_object_initializer_expression?/1)

  defp invalid_object_initializer_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &invalid_object_initializer_property?/1)

  defp invalid_object_initializer_expression?(_expression), do: false

  defp invalid_object_initializer_property?(%AST.Property{
         shorthand: true,
         value: %AST.AssignmentPattern{}
       }),
       do: true

  defp invalid_object_initializer_property?(%AST.Property{
         shorthand: true,
         value: %AST.Identifier{name: name}
       }),
       do: MapSet.member?(@reserved_assignment_property_names, name)

  defp invalid_object_initializer_property?(%AST.Property{
         key: %AST.Literal{},
         shorthand: true,
         method: false,
         computed: false
       }),
       do: true

  defp invalid_object_initializer_property?(_property), do: false

  def validate_class_element_names(state, body) do
    cond do
      Enum.any?(body, &invalid_class_method_name?/1) ->
        add_error(state, current(state), "invalid method name")

      Enum.any?(body, &invalid_class_field_name?/1) ->
        add_error(state, current(state), "invalid field name")

      true ->
        state
    end
  end

  defp invalid_class_method_name?(%AST.MethodDefinition{
         key: %AST.PrivateIdentifier{name: "constructor"}
       }),
       do: true

  defp invalid_class_method_name?(%AST.MethodDefinition{computed: true}), do: false

  defp invalid_class_method_name?(%AST.MethodDefinition{static: true, key: key}),
    do: prop_name(key) == "prototype"

  defp invalid_class_method_name?(%AST.MethodDefinition{key: %AST.Literal{value: "constructor"}}),
    do: false

  defp invalid_class_method_name?(%AST.MethodDefinition{kind: kind, key: key})
       when kind != :constructor,
       do: prop_name(key) == "constructor"

  defp invalid_class_method_name?(_element), do: false

  defp invalid_class_field_name?(%AST.FieldDefinition{
         key: %AST.PrivateIdentifier{name: "constructor"}
       }),
       do: true

  defp invalid_class_field_name?(%AST.FieldDefinition{computed: true}), do: false

  defp invalid_class_field_name?(%AST.FieldDefinition{key: key, static: static?}) do
    prop_name(key) == "constructor" or (static? and prop_name(key) == "prototype")
  end

  defp invalid_class_field_name?(_element), do: false

  defp prop_name(%AST.Identifier{name: name}), do: name
  defp prop_name(%AST.Literal{value: value}) when is_binary(value), do: value
  defp prop_name(_key), do: nil

  def validate_optional_chain_base(state, %AST.Identifier{name: "super"}) do
    add_error(state, current(state), "optional chain not allowed on super")
  end

  def validate_optional_chain_base(state, _left), do: state

  def validate_assignment_target(state, operator, left) when operator in @assignment_ops do
    cond do
      optional_chain?(left) ->
        add_error(state, current(state), "optional chain is not a valid assignment target")

      not valid_assignment_target?(operator, left) ->
        add_error(state, current(state), "invalid assignment target")

      invalid_assignment_pattern?(left, state) ->
        add_error(state, current(state), "invalid destructuring target")

      true ->
        state
    end
  end

  def validate_assignment_target(state, _operator, _left), do: state

  def validate_update_target(state, argument) do
    cond do
      optional_chain?(argument) ->
        add_error(state, current(state), "optional chain is not a valid assignment target")

      not valid_update_target?(argument) ->
        add_error(state, current(state), "invalid assignment target")

      true ->
        state
    end
  end

  defp valid_assignment_target?(_operator, %AST.Identifier{name: name})
       when name in ["this", "super"],
       do: false

  defp valid_assignment_target?(_operator, %AST.Identifier{}), do: true
  defp valid_assignment_target?(_operator, %AST.MemberExpression{}), do: true

  defp valid_assignment_target?(operator, %AST.CallExpression{})
       when operator in ["&&=", "||=", "??="],
       do: false

  defp valid_assignment_target?(_operator, %AST.CallExpression{}), do: true

  defp valid_assignment_target?("=", %AST.BinaryExpression{
         operator: "in",
         left: %AST.PrivateIdentifier{}
       }),
       do: true

  defp valid_assignment_target?("=", %AST.ObjectExpression{parenthesized?: true}), do: false
  defp valid_assignment_target?("=", %AST.ObjectExpression{}), do: true
  defp valid_assignment_target?("=", %AST.ArrayExpression{}), do: true
  defp valid_assignment_target?("=", %AST.ObjectPattern{parenthesized?: true}), do: false
  defp valid_assignment_target?("=", %AST.ObjectPattern{}), do: true
  defp valid_assignment_target?("=", %AST.ArrayPattern{}), do: true
  defp valid_assignment_target?(_operator, _target), do: false

  defp valid_update_target?(%AST.Identifier{name: name}) when name in ["this", "super"], do: false
  defp valid_update_target?(%AST.Identifier{}), do: true
  defp valid_update_target?(%AST.MemberExpression{}), do: true

  defp valid_update_target?(%AST.CallExpression{callee: %AST.Identifier{name: "import"}}),
    do: false

  defp valid_update_target?(%AST.CallExpression{}), do: true
  defp valid_update_target?(_target), do: false

  defp invalid_assignment_pattern?(%AST.ObjectPattern{properties: properties}, state) do
    invalid_rest_position?(properties) or
      Enum.any?(properties, &invalid_assignment_pattern?(&1, state))
  end

  defp invalid_assignment_pattern?(%AST.ArrayPattern{elements: elements}, state) do
    invalid_rest_position?(elements) or
      Enum.any?(elements, &invalid_assignment_pattern?(&1, state))
  end

  defp invalid_assignment_pattern?(%AST.Property{kind: kind}, _state) when kind in [:get, :set],
    do: true

  defp invalid_assignment_pattern?(%AST.Property{method: true}, _state), do: true

  defp invalid_assignment_pattern?(
         %AST.Property{shorthand: true, value: %AST.Identifier{name: name}},
         state
       ) do
    MapSet.member?(@reserved_assignment_property_names, name) or
      (name == "yield" and state.yield_allowed?) or (name == "await" and state.await_allowed?)
  end

  defp invalid_assignment_pattern?(%AST.Property{value: value}, state),
    do: invalid_assignment_pattern?(value, state)

  defp invalid_assignment_pattern?(%AST.RestElement{argument: %AST.AssignmentPattern{}}, _state),
    do: true

  defp invalid_assignment_pattern?(%AST.RestElement{argument: argument}, state),
    do: invalid_assignment_pattern?(argument, state)

  defp invalid_assignment_pattern?(%AST.AssignmentPattern{left: left}, state),
    do: invalid_assignment_pattern?(left, state)

  defp invalid_assignment_pattern?(%AST.SequenceExpression{}, _state), do: true
  defp invalid_assignment_pattern?(%AST.FunctionExpression{}, _state), do: true

  defp invalid_assignment_pattern?(_target, _state), do: false

  defp invalid_rest_position?(items) do
    last_index = length(items) - 1

    items
    |> Enum.with_index()
    |> Enum.any?(fn
      {%AST.RestElement{}, index} -> index != last_index
      {_item, _index} -> false
    end)
  end

  defp optional_chain?(%AST.MemberExpression{optional: true}), do: true
  defp optional_chain?(%AST.CallExpression{optional: true}), do: true
  defp optional_chain?(%AST.MemberExpression{object: object}), do: optional_chain?(object)
  defp optional_chain?(%AST.CallExpression{callee: callee}), do: optional_chain?(callee)

  defp optional_chain?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &optional_chain?/1)

  defp optional_chain?(%AST.ObjectPattern{properties: properties}),
    do: Enum.any?(properties, &optional_chain?/1)

  defp optional_chain?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &optional_chain?/1)

  defp optional_chain?(%AST.ArrayPattern{elements: elements}),
    do: Enum.any?(elements, &optional_chain?/1)

  defp optional_chain?(%AST.Property{value: value}), do: optional_chain?(value)
  defp optional_chain?(%AST.SpreadElement{argument: argument}), do: optional_chain?(argument)
  defp optional_chain?(_expression), do: false
end
