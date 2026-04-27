defmodule QuickBEAM.JS.Parser.Validation.Strict do
  @moduledoc "Strict-mode binding and expression validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_async_params(state, true, params) do
    if Enum.any?(identifier_param_names(params), &(&1 == "await")) do
      add_error(state, current(state), "await parameter not allowed in async function")
    else
      state
    end
  end

  def validate_async_params(state, _async?, _params), do: state

  def validate_generator_params(state, true, params) do
    if Enum.any?(identifier_param_names(params), &(&1 == "yield")) do
      add_error(state, current(state), "yield parameter not allowed in generator function")
    else
      state
    end
  end

  def validate_generator_params(state, _generator?, _params), do: state

  def validate_strict_function_name(
        state,
        %AST.Identifier{name: name},
        %AST.BlockStatement{} = body
      )
      when name in ["eval", "arguments"] do
    if strict_directive_body?(body.body) do
      add_error(state, current(state), "restricted binding name in strict mode")
    else
      state
    end
  end

  def validate_strict_function_name(state, _id, _body), do: state

  def validate_strict_program_bindings(state, body) do
    if state.source_type == :module or strict_directive_body?(body) do
      state
      |> validate_restricted_strict_names(
        program_binding_names(body),
        "restricted binding name in strict mode"
      )
      |> validate_strict_no_with(body)
      |> validate_strict_no_delete_identifier(body)
      |> validate_strict_no_legacy_octal(body)
      |> validate_strict_no_octal_escape(body)
      |> validate_strict_no_restricted_assignment(body)
    else
      state
    end
  end

  defp program_binding_names(body), do: Enum.flat_map(body, &statement_binding_names/1)

  defp statement_binding_names(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.flat_map(declarations, &binding_names(&1.id))
  end

  defp statement_binding_names(%AST.FunctionDeclaration{id: %AST.Identifier{name: name}}),
    do: [name]

  defp statement_binding_names(%AST.ClassDeclaration{id: %AST.Identifier{name: name}}), do: [name]
  defp statement_binding_names(%AST.BlockStatement{body: body}), do: program_binding_names(body)

  defp statement_binding_names(%AST.IfStatement{consequent: consequent, alternate: alternate}) do
    statement_binding_names(consequent) ++ statement_binding_names(alternate)
  end

  defp statement_binding_names(%AST.WhileStatement{body: body}), do: statement_binding_names(body)

  defp statement_binding_names(%AST.DoWhileStatement{body: body}),
    do: statement_binding_names(body)

  defp statement_binding_names(%AST.ForStatement{init: init, body: body}),
    do: binding_names_from_for_init(init) ++ statement_binding_names(body)

  defp statement_binding_names(%AST.ForInStatement{left: left, body: body}),
    do: binding_names_from_for_init(left) ++ statement_binding_names(body)

  defp statement_binding_names(%AST.ForOfStatement{left: left, body: body}),
    do: binding_names_from_for_init(left) ++ statement_binding_names(body)

  defp statement_binding_names(%AST.WithStatement{body: body}), do: statement_binding_names(body)

  defp statement_binding_names(%AST.SwitchStatement{cases: cases}) do
    Enum.flat_map(cases, &program_binding_names(&1.consequent))
  end

  defp statement_binding_names(%AST.TryStatement{
         block: block,
         handler: handler,
         finalizer: finalizer
       }) do
    statement_binding_names(block) ++
      catch_binding_names(handler) ++ statement_binding_names(finalizer)
  end

  defp statement_binding_names(_statement), do: []

  defp binding_names_from_for_init(%AST.VariableDeclaration{} = declaration),
    do: statement_binding_names(declaration)

  defp binding_names_from_for_init(_init), do: []

  defp catch_binding_names(%AST.CatchClause{param: nil, body: body}),
    do: statement_binding_names(body)

  defp catch_binding_names(%AST.CatchClause{param: param, body: body}),
    do: binding_names(param) ++ statement_binding_names(body)

  defp catch_binding_names(_handler), do: []

  def validate_arrow_params(state, params, body) do
    state
    |> validate_duplicate_strict_params(params)
    |> validate_strict_function_params(params, body)
  end

  def validate_strict_function_params(state, params, %AST.BlockStatement{} = body) do
    if strict_directive_body?(body.body) do
      state
      |> validate_duplicate_strict_params(params)
      |> validate_restricted_strict_params(params)
      |> validate_restricted_strict_names(
        program_binding_names(body.body),
        "restricted binding name in strict mode"
      )
      |> validate_strict_no_with(body.body)
      |> validate_strict_no_delete_identifier(body.body)
      |> validate_strict_no_legacy_octal(body.body)
      |> validate_strict_no_octal_escape(body.body)
      |> validate_strict_no_restricted_assignment(body.body)
    else
      state
    end
  end

  def validate_strict_function_params(state, _params, _body), do: state

  defp strict_directive_body?([
         %AST.ExpressionStatement{expression: %AST.Literal{value: "use strict"}} | _rest
       ]),
       do: true

  defp strict_directive_body?([
         %AST.ExpressionStatement{expression: %AST.Literal{value: value}} | rest
       ])
       when is_binary(value),
       do: strict_directive_body?(rest)

  defp strict_directive_body?(_body), do: false

  def validate_strict_params(state, params) do
    state
    |> validate_duplicate_strict_params(params)
    |> validate_restricted_strict_params(params)
  end

  def validate_strict_body_bindings(state, %AST.BlockStatement{} = body) do
    state
    |> validate_restricted_strict_names(
      program_binding_names(body.body),
      "restricted binding name in strict mode"
    )
    |> validate_strict_no_with(body.body)
    |> validate_strict_no_delete_identifier(body.body)
    |> validate_strict_no_legacy_octal(body.body)
    |> validate_strict_no_octal_escape(body.body)
    |> validate_strict_no_restricted_assignment(body.body)
  end

  defp validate_duplicate_strict_params(state, params) do
    names = identifier_param_names(params)

    if length(names) != length(Enum.uniq(names)) do
      add_error(state, current(state), "duplicate parameter name not allowed in strict mode")
    else
      state
    end
  end

  defp validate_restricted_strict_params(state, params) do
    validate_restricted_strict_names(
      state,
      identifier_param_names(params),
      "restricted parameter name in strict mode"
    )
  end

  defp validate_restricted_strict_names(state, names, message) do
    if Enum.any?(names, &restricted_strict_name?/1) do
      add_error(state, current(state), message)
    else
      state
    end
  end

  defp restricted_strict_name?(name) do
    name in [
      "eval",
      "arguments",
      "yield",
      "let",
      "static",
      "implements",
      "interface",
      "package",
      "private",
      "protected",
      "public"
    ]
  end

  defp validate_strict_no_with(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_with_statement?/1) do
      add_error(state, current(state), "with statement not allowed in strict mode")
    else
      state
    end
  end

  defp strict_with_statement?(%AST.WithStatement{}), do: true

  defp strict_with_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_with_statement?/1)

  defp strict_with_statement?(%AST.IfStatement{consequent: consequent, alternate: alternate}),
    do: strict_with_statement?(consequent) or strict_with_statement?(alternate)

  defp strict_with_statement?(%AST.WhileStatement{body: body}), do: strict_with_statement?(body)
  defp strict_with_statement?(%AST.DoWhileStatement{body: body}), do: strict_with_statement?(body)
  defp strict_with_statement?(%AST.ForStatement{body: body}), do: strict_with_statement?(body)
  defp strict_with_statement?(%AST.ForInStatement{body: body}), do: strict_with_statement?(body)
  defp strict_with_statement?(%AST.ForOfStatement{body: body}), do: strict_with_statement?(body)

  defp strict_with_statement?(%AST.FunctionDeclaration{body: body}),
    do: strict_with_statement?(body)

  defp strict_with_statement?(%AST.SwitchStatement{cases: cases}) do
    Enum.any?(cases, fn %AST.SwitchCase{consequent: consequent} ->
      Enum.any?(consequent, &strict_with_statement?/1)
    end)
  end

  defp strict_with_statement?(%AST.TryStatement{
         block: block,
         handler: handler,
         finalizer: finalizer
       }) do
    strict_with_statement?(block) or strict_with_statement?(handler) or
      strict_with_statement?(finalizer)
  end

  defp strict_with_statement?(%AST.CatchClause{body: body}), do: strict_with_statement?(body)
  defp strict_with_statement?(_statement), do: false

  defp validate_strict_no_delete_identifier(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_delete_identifier_statement?/1) do
      add_error(state, current(state), "delete of identifier not allowed in strict mode")
    else
      state
    end
  end

  defp strict_delete_identifier_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_delete_identifier_expression?(expression)

  defp strict_delete_identifier_statement?(%AST.ReturnStatement{argument: argument}),
    do: strict_delete_identifier_expression?(argument)

  defp strict_delete_identifier_statement?(%AST.ThrowStatement{argument: argument}),
    do: strict_delete_identifier_expression?(argument)

  defp strict_delete_identifier_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &strict_delete_identifier_expression?(&1.init))
  end

  defp strict_delete_identifier_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_delete_identifier_statement?/1)

  defp strict_delete_identifier_statement?(%AST.IfStatement{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    strict_delete_identifier_expression?(test) or strict_delete_identifier_statement?(consequent) or
      strict_delete_identifier_statement?(alternate)
  end

  defp strict_delete_identifier_statement?(%AST.WhileStatement{test: test, body: body}),
    do: strict_delete_identifier_expression?(test) or strict_delete_identifier_statement?(body)

  defp strict_delete_identifier_statement?(%AST.DoWhileStatement{body: body, test: test}),
    do: strict_delete_identifier_statement?(body) or strict_delete_identifier_expression?(test)

  defp strict_delete_identifier_statement?(%AST.ForStatement{
         init: init,
         test: test,
         update: update,
         body: body
       }) do
    strict_delete_identifier_expression?(init) or strict_delete_identifier_expression?(test) or
      strict_delete_identifier_expression?(update) or strict_delete_identifier_statement?(body)
  end

  defp strict_delete_identifier_statement?(%AST.SwitchStatement{
         discriminant: discriminant,
         cases: cases
       }) do
    strict_delete_identifier_expression?(discriminant) or
      Enum.any?(cases, fn %AST.SwitchCase{test: test, consequent: consequent} ->
        strict_delete_identifier_expression?(test) or
          Enum.any?(consequent, &strict_delete_identifier_statement?/1)
      end)
  end

  defp strict_delete_identifier_statement?(%AST.TryStatement{
         block: block,
         handler: handler,
         finalizer: finalizer
       }) do
    strict_delete_identifier_statement?(block) or strict_delete_identifier_statement?(handler) or
      strict_delete_identifier_statement?(finalizer)
  end

  defp strict_delete_identifier_statement?(%AST.CatchClause{body: body}),
    do: strict_delete_identifier_statement?(body)

  defp strict_delete_identifier_statement?(_statement), do: false

  defp strict_delete_identifier_expression?(%AST.UnaryExpression{
         operator: "delete",
         argument: %AST.Identifier{}
       }),
       do: true

  defp strict_delete_identifier_expression?(%AST.UnaryExpression{argument: argument}),
    do: strict_delete_identifier_expression?(argument)

  defp strict_delete_identifier_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: strict_delete_identifier_expression?(left) or strict_delete_identifier_expression?(right)

  defp strict_delete_identifier_expression?(%AST.LogicalExpression{left: left, right: right}),
    do: strict_delete_identifier_expression?(left) or strict_delete_identifier_expression?(right)

  defp strict_delete_identifier_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_delete_identifier_expression?(left) or strict_delete_identifier_expression?(right)

  defp strict_delete_identifier_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_delete_identifier_expression?/1)

  defp strict_delete_identifier_expression?(%AST.ConditionalExpression{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    strict_delete_identifier_expression?(test) or strict_delete_identifier_expression?(consequent) or
      strict_delete_identifier_expression?(alternate)
  end

  defp strict_delete_identifier_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }) do
    strict_delete_identifier_expression?(callee) or
      Enum.any?(arguments, &strict_delete_identifier_expression?/1)
  end

  defp strict_delete_identifier_expression?(%AST.MemberExpression{
         object: object,
         property: property
       }),
       do:
         strict_delete_identifier_expression?(object) or
           strict_delete_identifier_expression?(property)

  defp strict_delete_identifier_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &strict_delete_identifier_expression?/1)

  defp strict_delete_identifier_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_delete_identifier_expression?/1)

  defp strict_delete_identifier_expression?(%AST.Property{value: value}),
    do: strict_delete_identifier_expression?(value)

  defp strict_delete_identifier_expression?(%AST.SpreadElement{argument: argument}),
    do: strict_delete_identifier_expression?(argument)

  defp strict_delete_identifier_expression?(_expression), do: false

  defp validate_strict_no_legacy_octal(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_legacy_octal_statement?/1) do
      add_error(state, current(state), "legacy octal literal not allowed in strict mode")
    else
      state
    end
  end

  defp strict_legacy_octal_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_legacy_octal_expression?(expression)

  defp strict_legacy_octal_statement?(%AST.ReturnStatement{argument: argument}),
    do: strict_legacy_octal_expression?(argument)

  defp strict_legacy_octal_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &strict_legacy_octal_expression?(&1.init))
  end

  defp strict_legacy_octal_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_legacy_octal_statement?/1)

  defp strict_legacy_octal_statement?(%AST.IfStatement{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    strict_legacy_octal_expression?(test) or strict_legacy_octal_statement?(consequent) or
      strict_legacy_octal_statement?(alternate)
  end

  defp strict_legacy_octal_statement?(_statement), do: false

  defp strict_legacy_octal_expression?(%AST.Literal{raw: raw}) when is_binary(raw) do
    String.match?(raw, ~r/^0[0-9]/)
  end

  defp strict_legacy_octal_expression?(%AST.UnaryExpression{argument: argument}),
    do: strict_legacy_octal_expression?(argument)

  defp strict_legacy_octal_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: strict_legacy_octal_expression?(left) or strict_legacy_octal_expression?(right)

  defp strict_legacy_octal_expression?(%AST.LogicalExpression{left: left, right: right}),
    do: strict_legacy_octal_expression?(left) or strict_legacy_octal_expression?(right)

  defp strict_legacy_octal_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_legacy_octal_expression?(left) or strict_legacy_octal_expression?(right)

  defp strict_legacy_octal_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_legacy_octal_expression?/1)

  defp strict_legacy_octal_expression?(%AST.CallExpression{callee: callee, arguments: arguments}),
    do:
      strict_legacy_octal_expression?(callee) or
        Enum.any?(arguments, &strict_legacy_octal_expression?/1)

  defp strict_legacy_octal_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &strict_legacy_octal_expression?/1)

  defp strict_legacy_octal_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_legacy_octal_expression?/1)

  defp strict_legacy_octal_expression?(%AST.Property{value: value}),
    do: strict_legacy_octal_expression?(value)

  defp strict_legacy_octal_expression?(_expression), do: false

  defp validate_strict_no_octal_escape(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_octal_escape_statement?/1) do
      add_error(state, current(state), "octal escape sequence not allowed in strict mode")
    else
      state
    end
  end

  defp strict_octal_escape_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_octal_escape_expression?(expression)

  defp strict_octal_escape_statement?(%AST.ReturnStatement{argument: argument}),
    do: strict_octal_escape_expression?(argument)

  defp strict_octal_escape_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &strict_octal_escape_expression?(&1.init))
  end

  defp strict_octal_escape_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_octal_escape_statement?/1)

  defp strict_octal_escape_statement?(_statement), do: false

  defp strict_octal_escape_expression?(%AST.Literal{raw: raw}) when is_binary(raw) do
    String.match?(raw, ~r/\\(?:[1-7]|0[0-9])/)
  end

  defp strict_octal_escape_expression?(%AST.UnaryExpression{argument: argument}),
    do: strict_octal_escape_expression?(argument)

  defp strict_octal_escape_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: strict_octal_escape_expression?(left) or strict_octal_escape_expression?(right)

  defp strict_octal_escape_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_octal_escape_expression?(left) or strict_octal_escape_expression?(right)

  defp strict_octal_escape_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_octal_escape_expression?/1)

  defp strict_octal_escape_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &strict_octal_escape_expression?/1)

  defp strict_octal_escape_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_octal_escape_expression?/1)

  defp strict_octal_escape_expression?(%AST.Property{value: value}),
    do: strict_octal_escape_expression?(value)

  defp strict_octal_escape_expression?(_expression), do: false

  defp validate_strict_no_restricted_assignment(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_restricted_assignment_statement?/1) do
      add_error(state, current(state), "restricted assignment target in strict mode")
    else
      state
    end
  end

  defp strict_restricted_assignment_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_restricted_assignment_expression?(expression)

  defp strict_restricted_assignment_statement?(%AST.ReturnStatement{argument: argument}),
    do: strict_restricted_assignment_expression?(argument)

  defp strict_restricted_assignment_statement?(%AST.VariableDeclaration{
         declarations: declarations
       }) do
    Enum.any?(declarations, &strict_restricted_assignment_expression?(&1.init))
  end

  defp strict_restricted_assignment_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_restricted_assignment_statement?/1)

  defp strict_restricted_assignment_statement?(_statement), do: false

  defp strict_restricted_assignment_expression?(%AST.AssignmentExpression{
         left: left,
         right: right
       }),
       do:
         restricted_assignment_target?(left) or
           strict_restricted_assignment_expression?(right)

  defp strict_restricted_assignment_expression?(%AST.BinaryExpression{left: left, right: right}),
    do:
      strict_restricted_assignment_expression?(left) or
        strict_restricted_assignment_expression?(right)

  defp strict_restricted_assignment_expression?(%AST.LogicalExpression{left: left, right: right}),
    do:
      strict_restricted_assignment_expression?(left) or
        strict_restricted_assignment_expression?(right)

  defp strict_restricted_assignment_expression?(%AST.UpdateExpression{argument: argument}),
    do: restricted_assignment_target?(argument)

  defp strict_restricted_assignment_expression?(%AST.SequenceExpression{
         expressions: expressions
       }),
       do: Enum.any?(expressions, &strict_restricted_assignment_expression?/1)

  defp strict_restricted_assignment_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }),
       do:
         strict_restricted_assignment_expression?(callee) or
           Enum.any?(arguments, &strict_restricted_assignment_expression?/1)

  defp strict_restricted_assignment_expression?(_expression), do: false

  defp restricted_assignment_target?(%AST.Identifier{name: name})
       when name in ["eval", "arguments"],
       do: true

  defp restricted_assignment_target?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &restricted_assignment_target?/1)

  defp restricted_assignment_target?(%AST.ObjectPattern{properties: properties}),
    do: Enum.any?(properties, &restricted_assignment_target?/1)

  defp restricted_assignment_target?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &restricted_assignment_target?/1)

  defp restricted_assignment_target?(%AST.ArrayPattern{elements: elements}),
    do: Enum.any?(elements, &restricted_assignment_target?/1)

  defp restricted_assignment_target?(%AST.Property{value: value}),
    do: restricted_assignment_target?(value)

  defp restricted_assignment_target?(%AST.SpreadElement{argument: argument}),
    do: restricted_assignment_target?(argument)

  defp restricted_assignment_target?(%AST.AssignmentPattern{left: left}),
    do: restricted_assignment_target?(left)

  defp restricted_assignment_target?(_target), do: false
  defp identifier_param_names(params), do: Enum.flat_map(params, &binding_names/1)

  defp binding_names(%AST.Identifier{name: name}), do: [name]
  defp binding_names(%AST.AssignmentPattern{left: left}), do: binding_names(left)
  defp binding_names(%AST.RestElement{argument: argument}), do: binding_names(argument)

  defp binding_names(%AST.ArrayPattern{elements: elements}),
    do: Enum.flat_map(elements, &binding_names/1)

  defp binding_names(%AST.ObjectPattern{properties: properties}),
    do: Enum.flat_map(properties, &binding_names/1)

  defp binding_names(%AST.Property{value: value}), do: binding_names(value)
  defp binding_names(nil), do: []
  defp binding_names(_param), do: []

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
