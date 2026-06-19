defmodule QuickBEAM.JS.Parser.Validation.Strict do
  @moduledoc "Strict-mode binding and expression validation."

  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.JS.Parser.Validation.Strict.AnnexB
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]
  import QuickBEAM.JS.Parser.Validation.Strict.Helpers

  def validate_strict_function_name(
        state,
        %AST.Identifier{name: name},
        %AST.BlockStatement{} = body
      ) do
    if restricted_strict_name?(name) and strict_directive_body?(body.body) do
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
      |> validate_strict_no_call_assignment_targets(body)
      |> AnnexB.validate_no_if_function_declarations(body)
      |> AnnexB.validate_no_for_in_initializers(body)
      |> AnnexB.validate_no_duplicate_block_function_declarations(body)
      |> AnnexB.validate_no_duplicate_switch_function_declarations(body)
      |> validate_strict_no_yield_references(body)
      |> validate_strict_no_restricted_shorthands(body)
      |> validate_strict_no_restricted_labels(body)
      |> validate_strict_function_expressions(body)
    else
      state
    end
  end

  def validate_arrow_params(state, params, body) do
    state
    |> validate_arrow_context_params(params)
    |> validate_duplicate_strict_params(params)
    |> validate_strict_function_params(params, body)
  end

  defp validate_arrow_context_params(state, params) do
    names = binding_names(params)

    cond do
      Enum.any?(names, &(&1 == "enum")) ->
        add_error(state, current(state), "expected binding identifier")

      state.await_allowed? and Enum.any?(names, &(&1 == "await")) ->
        add_error(state, current(state), "await parameter not allowed in async function")

      state.await_allowed? and Enum.any?(params, &contains_await_expression?/1) ->
        add_error(state, current(state), "await parameter not allowed in async function")

      state.yield_allowed? and Enum.any?(names, &(&1 == "yield")) ->
        add_error(state, current(state), "yield parameter not allowed in generator function")

      state.yield_allowed? and Enum.any?(params, &contains_yield_expression?/1) ->
        add_error(state, current(state), "yield parameter not allowed in generator function")

      true ->
        state
    end
  end

  def validate_strict_function_params(state, params, %AST.BlockStatement{} = body) do
    state =
      state
      |> validate_non_simple_duplicate_params(params)
      |> validate_formal_body_lexical_conflicts(params, body.body)

    if strict_directive_body?(body.body) do
      state
      |> validate_strict_non_simple_params(params)
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
      |> validate_strict_no_call_assignment_targets(body.body)
      |> validate_strict_no_yield_references(body.body)
      |> validate_strict_no_restricted_shorthands(body.body)
    else
      state
    end
  end

  def validate_strict_function_params(state, _params, _body), do: state

  defp validate_formal_body_lexical_conflicts(state, params, body) do
    param_names = binding_names(params)
    lexical_names = function_body_lexical_names(body)

    if Enum.any?(param_names, &(&1 in lexical_names)) do
      add_error(state, current(state), "duplicate lexical declaration")
    else
      state
    end
  end

  defp function_body_lexical_names(body),
    do: Enum.flat_map(body, &function_body_statement_lexical_names/1)

  defp function_body_statement_lexical_names(%AST.VariableDeclaration{
         kind: kind,
         declarations: declarations
       })
       when kind in [:let, :const] do
    Enum.flat_map(declarations, &binding_names(&1.id))
  end

  defp function_body_statement_lexical_names(%AST.ClassDeclaration{
         id: %AST.Identifier{name: name}
       }),
       do: [name]

  defp function_body_statement_lexical_names(%AST.BlockStatement{}), do: []

  defp function_body_statement_lexical_names(_statement), do: []

  defp validate_non_simple_duplicate_params(state, params) do
    names = identifier_param_names(params)

    if Enum.any?(params, &(not simple_param?(&1))) and length(names) != length(Enum.uniq(names)) do
      add_error(state, current(state), "duplicate parameter name not allowed in strict mode")
    else
      state
    end
  end

  defp validate_strict_non_simple_params(state, params) do
    if Enum.any?(params, &(not simple_param?(&1))) do
      add_error(state, current(state), "use strict not allowed with non-simple parameters")
    else
      state
    end
  end

  defp simple_param?(%AST.Identifier{}), do: true
  defp simple_param?(_param), do: false

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
    |> validate_strict_no_call_assignment_targets(body.body)
    |> validate_strict_no_restricted_shorthands(body.body)
    |> validate_strict_function_expressions(body.body)
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

  defp validate_strict_no_with(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_with_statement?/1) do
      add_error(state, current(state), "with statement not allowed in strict mode")
    else
      state
    end
  end

  defp validate_strict_no_restricted_labels(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_restricted_label_statement?/1) do
      add_error(state, current(state), "restricted binding name in strict mode")
    else
      state
    end
  end

  defp strict_restricted_label_statement?(%AST.LabeledStatement{
         label: %AST.Identifier{name: name}
       }),
       do: restricted_strict_name?(name)

  defp strict_restricted_label_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_restricted_label_statement?/1)

  defp strict_restricted_label_statement?(_statement), do: false

  defp strict_with_statement?(%AST.WithStatement{}), do: true

  defp strict_with_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_with_statement?/1)

  defp strict_with_statement?(%AST.VariableDeclaration{declarations: declarations}),
    do: Enum.any?(declarations, &strict_with_statement?(&1.init))

  defp strict_with_statement?(%AST.FunctionExpression{body: body}),
    do: strict_with_statement?(body)

  defp strict_with_statement?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_with_statement?/1)

  defp strict_with_statement?(%AST.Property{value: value}), do: strict_with_statement?(value)

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
    String.match?(raw, ~r/\\(?:[1-9]|0[0-9])/)
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

  defp strict_octal_escape_expression?(%AST.TemplateLiteral{expressions: expressions}),
    do: Enum.any?(expressions, &strict_octal_escape_expression?/1)

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

  defp strict_restricted_assignment_statement?(%AST.ForOfStatement{
         left: left,
         right: right,
         body: body
       }),
       do:
         for_in_of_restricted_assignment_pattern?(left) or
           strict_restricted_assignment_expression?(right) or
           strict_restricted_assignment_statement?(body)

  defp strict_restricted_assignment_statement?(%AST.ForInStatement{
         left: left,
         right: right,
         body: body
       }),
       do:
         for_in_of_restricted_assignment_pattern?(left) or
           strict_restricted_assignment_expression?(right) or
           strict_restricted_assignment_statement?(body)

  defp strict_restricted_assignment_statement?(%AST.FunctionDeclaration{body: body}),
    do: strict_restricted_assignment_statement?(body)

  defp strict_restricted_assignment_statement?(_statement), do: false

  defp strict_restricted_assignment_expression?(%AST.AssignmentExpression{
         left: left,
         right: right
       }),
       do:
         restricted_assignment_target?(left) or
           strict_restricted_assignment_expression?(right)

  defp strict_restricted_assignment_expression?(%AST.UnaryExpression{argument: argument}),
    do: strict_restricted_assignment_expression?(argument)

  defp strict_restricted_assignment_expression?(%AST.FunctionExpression{
         body: %AST.BlockStatement{body: body}
       }),
       do: Enum.any?(body, &strict_restricted_assignment_statement?/1)

  defp strict_restricted_assignment_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_restricted_assignment_expression?/1)

  defp strict_restricted_assignment_expression?(%AST.Property{value: value}),
    do: strict_restricted_assignment_expression?(value)

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

  defp for_in_of_restricted_assignment_pattern?(%AST.AssignmentExpression{
         left: left,
         right: right
       }),
       do:
         for_in_of_restricted_assignment_pattern?(left) or
           for_in_of_restricted_assignment_pattern?(right)

  defp for_in_of_restricted_assignment_pattern?(%AST.MemberExpression{
         object: object,
         property: property
       }),
       do:
         for_in_of_restricted_assignment_pattern?(object) or
           for_in_of_restricted_assignment_pattern?(property)

  defp for_in_of_restricted_assignment_pattern?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &for_in_of_restricted_assignment_pattern?/1)

  defp for_in_of_restricted_assignment_pattern?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &for_in_of_restricted_assignment_pattern?/1)

  defp for_in_of_restricted_assignment_pattern?(%AST.Property{value: value}),
    do: for_in_of_restricted_assignment_pattern?(value)

  defp for_in_of_restricted_assignment_pattern?(%AST.SpreadElement{argument: argument}),
    do: for_in_of_restricted_assignment_pattern?(argument)

  defp for_in_of_restricted_assignment_pattern?(%AST.AssignmentPattern{left: left, right: right}),
    do:
      for_in_of_restricted_assignment_pattern?(left) or
        for_in_of_restricted_assignment_pattern?(right)

  defp for_in_of_restricted_assignment_pattern?(target), do: restricted_assignment_target?(target)

  defp restricted_assignment_target?(%AST.Identifier{name: name}),
    do: restricted_strict_name?(name)

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

  defp validate_strict_no_call_assignment_targets(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_call_assignment_statement?/1) do
      add_error(state, current(state), "invalid assignment target")
    else
      state
    end
  end

  defp validate_strict_no_yield_references(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_yield_reference_statement?/1) do
      add_error(state, current(state), "yield expression not within generator")
    else
      state
    end
  end

  defp validate_strict_no_restricted_shorthands(state, statements) when is_list(statements) do
    if Enum.any?(statements, &strict_restricted_shorthand_statement?/1) do
      add_error(state, current(state), "invalid object shorthand")
    else
      state
    end
  end

  defp strict_restricted_shorthand_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_restricted_shorthand_expression?(expression)

  defp strict_restricted_shorthand_statement?(%AST.ReturnStatement{argument: argument}),
    do: strict_restricted_shorthand_expression?(argument)

  defp strict_restricted_shorthand_statement?(%AST.VariableDeclaration{
         declarations: declarations
       }) do
    Enum.any?(declarations, &strict_restricted_shorthand_expression?(&1.init))
  end

  defp strict_restricted_shorthand_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_restricted_shorthand_statement?/1)

  defp strict_restricted_shorthand_statement?(_statement), do: false

  defp strict_restricted_shorthand_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_restricted_shorthand_expression?/1)

  defp strict_restricted_shorthand_expression?(%AST.Property{
         shorthand: true,
         value: %AST.Identifier{name: name}
       }),
       do: restricted_strict_name?(name)

  defp strict_restricted_shorthand_expression?(%AST.Property{value: value}),
    do: strict_restricted_shorthand_expression?(value)

  defp strict_restricted_shorthand_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_restricted_shorthand_expression?/1)

  defp strict_restricted_shorthand_expression?(_expression), do: false

  defp strict_yield_reference_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_yield_reference_expression?(expression)

  defp strict_yield_reference_statement?(%AST.ReturnStatement{argument: argument}),
    do: strict_yield_reference_expression?(argument)

  defp strict_yield_reference_statement?(%AST.IfStatement{
         test: test,
         consequent: consequent,
         alternate: alternate
       }),
       do:
         strict_yield_reference_expression?(test) or
           strict_yield_reference_statement?(consequent) or
           strict_yield_reference_statement?(alternate)

  defp strict_yield_reference_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_yield_reference_statement?/1)

  defp strict_yield_reference_statement?(_statement), do: false

  defp strict_yield_reference_expression?(%AST.Identifier{name: name}),
    do: restricted_strict_name?(name) and name not in ["eval", "arguments"]

  defp strict_yield_reference_expression?(%AST.UnaryExpression{argument: argument}),
    do: strict_yield_reference_expression?(argument)

  defp strict_yield_reference_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }),
       do:
         strict_yield_reference_expression?(callee) or
           Enum.any?(arguments, &strict_yield_reference_expression?/1)

  defp strict_yield_reference_expression?(%AST.FunctionExpression{
         body: %AST.BlockStatement{body: body}
       }),
       do: Enum.any?(body, &strict_yield_reference_statement?/1)

  defp strict_yield_reference_expression?(%AST.ConditionalExpression{
         test: test,
         consequent: consequent,
         alternate: alternate
       }),
       do:
         strict_yield_reference_expression?(test) or
           strict_yield_reference_expression?(consequent) or
           strict_yield_reference_expression?(alternate)

  defp strict_yield_reference_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: strict_yield_reference_expression?(left) or strict_yield_reference_expression?(right)

  defp strict_yield_reference_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_yield_reference_expression?(left) or strict_yield_reference_expression?(right)

  defp strict_yield_reference_expression?(%AST.MemberExpression{
         object: object,
         property: property
       }),
       do:
         strict_yield_reference_expression?(object) or
           strict_yield_reference_expression?(property)

  defp strict_yield_reference_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &strict_yield_reference_expression?/1)

  defp strict_yield_reference_expression?(%AST.ArrayPattern{elements: elements}),
    do: Enum.any?(elements, &strict_yield_reference_expression?/1)

  defp strict_yield_reference_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_yield_reference_expression?/1)

  defp strict_yield_reference_expression?(%AST.ObjectPattern{properties: properties}),
    do: Enum.any?(properties, &strict_yield_reference_expression?/1)

  defp strict_yield_reference_expression?(%AST.AssignmentPattern{left: left, right: right}),
    do: strict_yield_reference_expression?(left) or strict_yield_reference_expression?(right)

  defp strict_yield_reference_expression?(%AST.Property{key: key, value: value}),
    do: strict_yield_reference_expression?(key) or strict_yield_reference_expression?(value)

  defp strict_yield_reference_expression?(%AST.SpreadElement{argument: argument}),
    do: strict_yield_reference_expression?(argument)

  defp strict_yield_reference_expression?(%AST.RestElement{argument: argument}),
    do: strict_yield_reference_expression?(argument)

  defp strict_yield_reference_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_yield_reference_expression?/1)

  defp strict_yield_reference_expression?(_expression), do: false

  defp validate_strict_function_expressions(state, statements) when is_list(statements) do
    cond do
      Enum.any?(statements, &strict_duplicate_param_statement?/1) ->
        add_error(state, current(state), "duplicate parameter name not allowed in strict mode")

      Enum.any?(statements, &strict_restricted_function_name_statement?/1) ->
        add_error(state, current(state), "restricted binding name in strict mode")

      Enum.any?(statements, &strict_restricted_param_statement?/1) ->
        add_error(state, current(state), "restricted parameter name in strict mode")

      Enum.any?(statements, &strict_yield_param_statement?/1) ->
        add_error(state, current(state), "yield parameter not allowed in generator function")

      true ->
        state
    end
  end

  defp strict_duplicate_param_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_duplicate_param_expression?(expression)

  defp strict_duplicate_param_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &strict_duplicate_param_expression?(&1.init))
  end

  defp strict_duplicate_param_statement?(%AST.FunctionDeclaration{params: params, body: body}),
    do: duplicate_param_names?(params) or strict_duplicate_param_statement?(body)

  defp strict_duplicate_param_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_duplicate_param_statement?/1)

  defp strict_duplicate_param_statement?(_statement), do: false

  defp strict_duplicate_param_expression?(%AST.FunctionExpression{params: params}),
    do: duplicate_param_names?(params)

  defp strict_duplicate_param_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_duplicate_param_expression?(left) or strict_duplicate_param_expression?(right)

  defp strict_duplicate_param_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_duplicate_param_expression?/1)

  defp strict_duplicate_param_expression?(_expression), do: false

  defp strict_restricted_function_name_statement?(%AST.ExpressionStatement{
         expression: expression
       }),
       do: strict_restricted_function_name_expression?(expression)

  defp strict_restricted_function_name_statement?(%AST.VariableDeclaration{
         declarations: declarations
       }) do
    Enum.any?(declarations, &strict_restricted_function_name_expression?(&1.init))
  end

  defp strict_restricted_function_name_statement?(%AST.FunctionDeclaration{
         id: %AST.Identifier{name: name},
         body: body
       }),
       do: name in ["eval", "arguments"] or strict_restricted_function_name_statement?(body)

  defp strict_restricted_function_name_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_restricted_function_name_statement?/1)

  defp strict_restricted_function_name_statement?(_statement), do: false

  defp strict_restricted_function_name_expression?(%AST.FunctionExpression{
         id: %AST.Identifier{name: name}
       }),
       do: restricted_strict_name?(name)

  defp strict_restricted_function_name_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }),
       do:
         strict_restricted_function_name_expression?(callee) or
           Enum.any?(arguments, &strict_restricted_function_name_expression?/1)

  defp strict_restricted_function_name_expression?(%AST.AssignmentExpression{
         left: left,
         right: right
       }),
       do:
         strict_restricted_function_name_expression?(left) or
           strict_restricted_function_name_expression?(right)

  defp strict_restricted_function_name_expression?(%AST.SequenceExpression{
         expressions: expressions
       }),
       do: Enum.any?(expressions, &strict_restricted_function_name_expression?/1)

  defp strict_restricted_function_name_expression?(_expression), do: false

  defp strict_restricted_param_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_restricted_param_expression?(expression)

  defp strict_restricted_param_statement?(%AST.FunctionDeclaration{params: params}),
    do: Enum.any?(identifier_param_names(params), &restricted_strict_name?/1)

  defp strict_restricted_param_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &strict_restricted_param_expression?(&1.init))
  end

  defp strict_restricted_param_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_restricted_param_statement?/1)

  defp strict_restricted_param_statement?(_statement), do: false

  defp strict_restricted_param_expression?(%AST.FunctionExpression{params: params}),
    do: Enum.any?(identifier_param_names(params), &restricted_strict_name?/1)

  defp strict_restricted_param_expression?(%AST.ArrowFunctionExpression{params: params}),
    do: Enum.any?(identifier_param_names(params), &restricted_strict_name?/1)

  defp strict_restricted_param_expression?(%AST.UnaryExpression{argument: argument}),
    do: strict_restricted_param_expression?(argument)

  defp strict_restricted_param_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &strict_restricted_param_expression?/1)

  defp strict_restricted_param_expression?(%AST.Property{value: value}),
    do: strict_restricted_param_expression?(value)

  defp strict_restricted_param_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }),
       do:
         strict_restricted_param_expression?(callee) or
           Enum.any?(arguments, &strict_restricted_param_expression?/1)

  defp strict_restricted_param_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_restricted_param_expression?(left) or strict_restricted_param_expression?(right)

  defp strict_restricted_param_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_restricted_param_expression?/1)

  defp strict_restricted_param_expression?(_expression), do: false

  defp strict_yield_param_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_yield_param_expression?(expression)

  defp strict_yield_param_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &strict_yield_param_expression?(&1.init))
  end

  defp strict_yield_param_statement?(%AST.FunctionDeclaration{params: params, body: body}),
    do: Enum.any?(params, &contains_yield_expression?/1) or strict_yield_param_statement?(body)

  defp strict_yield_param_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_yield_param_statement?/1)

  defp strict_yield_param_statement?(_statement), do: false

  defp strict_yield_param_expression?(%AST.FunctionExpression{params: params}),
    do: Enum.any?(params, &contains_yield_expression?/1)

  defp strict_yield_param_expression?(%AST.ArrowFunctionExpression{params: params}),
    do: Enum.any?(params, &contains_yield_expression?/1)

  defp strict_yield_param_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_yield_param_expression?(left) or strict_yield_param_expression?(right)

  defp strict_yield_param_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_yield_param_expression?/1)

  defp strict_yield_param_expression?(_expression), do: false

  defp strict_call_assignment_statement?(%AST.ExpressionStatement{expression: expression}),
    do: strict_call_assignment_expression?(expression)

  defp strict_call_assignment_statement?(%AST.VariableDeclaration{declarations: declarations}),
    do: Enum.any?(declarations, &strict_call_assignment_expression?(&1.init))

  defp strict_call_assignment_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &strict_call_assignment_statement?/1)

  defp strict_call_assignment_statement?(%AST.ForInStatement{left: %AST.CallExpression{}}),
    do: true

  defp strict_call_assignment_statement?(%AST.ForOfStatement{left: %AST.CallExpression{}}),
    do: true

  defp strict_call_assignment_statement?(%AST.ForInStatement{
         left: left,
         right: right,
         body: body
       }),
       do:
         strict_call_assignment_expression?(left) or strict_call_assignment_expression?(right) or
           strict_call_assignment_statement?(body)

  defp strict_call_assignment_statement?(%AST.ForOfStatement{
         left: left,
         right: right,
         body: body
       }),
       do:
         strict_call_assignment_expression?(left) or strict_call_assignment_expression?(right) or
           strict_call_assignment_statement?(body)

  defp strict_call_assignment_statement?(_statement), do: false

  defp strict_call_assignment_expression?(%AST.AssignmentExpression{left: %AST.CallExpression{}}),
    do: true

  defp strict_call_assignment_expression?(%AST.UpdateExpression{argument: %AST.CallExpression{}}),
    do: true

  defp strict_call_assignment_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: strict_call_assignment_expression?(left) or strict_call_assignment_expression?(right)

  defp strict_call_assignment_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &strict_call_assignment_expression?/1)

  defp strict_call_assignment_expression?(%AST.CallExpression{
         callee: callee,
         arguments: arguments
       }),
       do:
         strict_call_assignment_expression?(callee) or
           Enum.any?(arguments, &strict_call_assignment_expression?/1)

  defp strict_call_assignment_expression?(%AST.MemberExpression{
         object: object,
         property: property,
         computed: computed?
       }) do
    strict_call_assignment_expression?(object) or
      (computed? and strict_call_assignment_expression?(property))
  end

  defp strict_call_assignment_expression?(_expression), do: false
end
