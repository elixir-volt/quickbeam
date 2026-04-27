defmodule QuickBEAM.JS.Parser.Validation.Proto do
  @moduledoc "Object initializer __proto__ validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_duplicate_proto_initializers(state, body) do
    if Enum.any?(body, &duplicate_proto_initializer_statement?/1) do
      add_error(state, current(state), "duplicate __proto__ property")
    else
      state
    end
  end

  defp duplicate_proto_initializer_statement?(%AST.ExpressionStatement{expression: expression}),
    do: duplicate_proto_initializer_expression?(expression)

  defp duplicate_proto_initializer_statement?(%AST.ReturnStatement{argument: argument}),
    do: duplicate_proto_initializer_expression?(argument)

  defp duplicate_proto_initializer_statement?(%AST.ThrowStatement{argument: argument}),
    do: duplicate_proto_initializer_expression?(argument)

  defp duplicate_proto_initializer_statement?(%AST.VariableDeclaration{
         declarations: declarations
       }) do
    Enum.any?(declarations, &duplicate_proto_initializer_expression?(&1.init))
  end

  defp duplicate_proto_initializer_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &duplicate_proto_initializer_statement?/1)

  defp duplicate_proto_initializer_statement?(%AST.FunctionDeclaration{}), do: false

  defp duplicate_proto_initializer_statement?(%AST.IfStatement{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    duplicate_proto_initializer_expression?(test) or
      duplicate_proto_initializer_statement?(consequent) or
      duplicate_proto_initializer_statement?(alternate)
  end

  defp duplicate_proto_initializer_statement?(%AST.WhileStatement{test: test, body: body}) do
    duplicate_proto_initializer_expression?(test) or duplicate_proto_initializer_statement?(body)
  end

  defp duplicate_proto_initializer_statement?(%AST.DoWhileStatement{body: body, test: test}) do
    duplicate_proto_initializer_statement?(body) or duplicate_proto_initializer_expression?(test)
  end

  defp duplicate_proto_initializer_statement?(%AST.ForStatement{
         init: init,
         test: test,
         update: update,
         body: body
       }) do
    duplicate_proto_initializer_expression?(init) or duplicate_proto_initializer_expression?(test) or
      duplicate_proto_initializer_expression?(update) or
      duplicate_proto_initializer_statement?(body)
  end

  defp duplicate_proto_initializer_statement?(%AST.ForInStatement{
         left: left,
         right: right,
         body: body
       }) do
    duplicate_proto_initializer_expression?(left) or
      duplicate_proto_initializer_expression?(right) or
      duplicate_proto_initializer_statement?(body)
  end

  defp duplicate_proto_initializer_statement?(%AST.ForOfStatement{
         left: left,
         right: right,
         body: body
       }) do
    duplicate_proto_initializer_expression?(left) or
      duplicate_proto_initializer_expression?(right) or
      duplicate_proto_initializer_statement?(body)
  end

  defp duplicate_proto_initializer_statement?(%AST.SwitchStatement{
         discriminant: discriminant,
         cases: cases
       }) do
    duplicate_proto_initializer_expression?(discriminant) or
      Enum.any?(cases, fn switch_case ->
        duplicate_proto_initializer_expression?(switch_case.test) or
          Enum.any?(switch_case.consequent, &duplicate_proto_initializer_statement?/1)
      end)
  end

  defp duplicate_proto_initializer_statement?(%AST.TryStatement{
         block: block,
         handler: handler,
         finalizer: finalizer
       }) do
    duplicate_proto_initializer_statement?(block) or
      duplicate_proto_initializer_statement?(handler) or
      duplicate_proto_initializer_statement?(finalizer)
  end

  defp duplicate_proto_initializer_statement?(%AST.CatchClause{body: body}),
    do: duplicate_proto_initializer_statement?(body)

  defp duplicate_proto_initializer_statement?(%AST.LabeledStatement{body: body}),
    do: duplicate_proto_initializer_statement?(body)

  defp duplicate_proto_initializer_statement?(_statement), do: false

  defp duplicate_proto_initializer_expression?(nil), do: false

  defp duplicate_proto_initializer_expression?(%AST.ObjectExpression{properties: properties}) do
    Enum.count(properties, &proto_data_property?/1) > 1 or
      Enum.any?(properties, &duplicate_proto_initializer_expression?/1)
  end

  defp duplicate_proto_initializer_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &duplicate_proto_initializer_expression?/1)

  defp duplicate_proto_initializer_expression?(%AST.Property{
         key: key,
         value: value,
         computed: computed?
       }) do
    (computed? and duplicate_proto_initializer_expression?(key)) or
      duplicate_proto_initializer_expression?(value)
  end

  defp duplicate_proto_initializer_expression?(%AST.SpreadElement{argument: argument}),
    do: duplicate_proto_initializer_expression?(argument)

  defp duplicate_proto_initializer_expression?(%AST.UnaryExpression{argument: argument}),
    do: duplicate_proto_initializer_expression?(argument)

  defp duplicate_proto_initializer_expression?(%AST.UpdateExpression{argument: argument}),
    do: duplicate_proto_initializer_expression?(argument)

  defp duplicate_proto_initializer_expression?(%AST.BinaryExpression{left: left, right: right}),
    do:
      duplicate_proto_initializer_expression?(left) or
        duplicate_proto_initializer_expression?(right)

  defp duplicate_proto_initializer_expression?(%AST.LogicalExpression{left: left, right: right}),
    do:
      duplicate_proto_initializer_expression?(left) or
        duplicate_proto_initializer_expression?(right)

  defp duplicate_proto_initializer_expression?(%AST.AssignmentExpression{
         left: left,
         right: right
       }),
       do:
         duplicate_proto_initializer_expression?(left) or
           duplicate_proto_initializer_expression?(right)

  defp duplicate_proto_initializer_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &duplicate_proto_initializer_expression?/1)

  defp duplicate_proto_initializer_expression?(%AST.ConditionalExpression{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    duplicate_proto_initializer_expression?(test) or
      duplicate_proto_initializer_expression?(consequent) or
      duplicate_proto_initializer_expression?(alternate)
  end

  defp duplicate_proto_initializer_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }) do
    duplicate_proto_initializer_expression?(callee) or
      Enum.any?(arguments, &duplicate_proto_initializer_expression?/1)
  end

  defp duplicate_proto_initializer_expression?(%AST.MemberExpression{
         object: object,
         property: property,
         computed: computed?
       }) do
    duplicate_proto_initializer_expression?(object) or
      (computed? and duplicate_proto_initializer_expression?(property))
  end

  defp duplicate_proto_initializer_expression?(%AST.FunctionExpression{}), do: false
  defp duplicate_proto_initializer_expression?(%AST.ArrowFunctionExpression{}), do: false
  defp duplicate_proto_initializer_expression?(_expression), do: false

  defp proto_data_property?(%AST.Property{
         key: %AST.Identifier{name: "__proto__"},
         kind: :init,
         computed: false,
         method: false,
         shorthand: false
       }),
       do: true

  defp proto_data_property?(%AST.Property{
         key: %AST.Literal{value: "__proto__"},
         kind: :init,
         computed: false,
         method: false,
         shorthand: false
       }),
       do: true

  defp proto_data_property?(_property), do: false

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
