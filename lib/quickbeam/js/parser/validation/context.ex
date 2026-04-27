defmodule QuickBEAM.JS.Parser.Validation.Context do
  @moduledoc "Context-sensitive expression validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_yield_context(state, body) do
    if Enum.any?(body, &invalid_yield_statement?/1) do
      add_error(state, current(state), "yield expression not within generator")
    else
      state
    end
  end

  defp invalid_yield_statement?(%AST.ExpressionStatement{expression: expression}),
    do: invalid_yield_expression?(expression)

  defp invalid_yield_statement?(%AST.ReturnStatement{argument: argument}),
    do: invalid_yield_expression?(argument)

  defp invalid_yield_statement?(%AST.ThrowStatement{argument: argument}),
    do: invalid_yield_expression?(argument)

  defp invalid_yield_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &invalid_yield_expression?(&1.init))
  end

  defp invalid_yield_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &invalid_yield_statement?/1)

  defp invalid_yield_statement?(%AST.FunctionDeclaration{generator: true}), do: false

  defp invalid_yield_statement?(%AST.FunctionDeclaration{body: body}),
    do: invalid_yield_statement?(body)

  defp invalid_yield_statement?(%AST.IfStatement{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    invalid_yield_expression?(test) or invalid_yield_statement?(consequent) or
      invalid_yield_statement?(alternate)
  end

  defp invalid_yield_statement?(%AST.WhileStatement{test: test, body: body}) do
    invalid_yield_expression?(test) or invalid_yield_statement?(body)
  end

  defp invalid_yield_statement?(%AST.DoWhileStatement{body: body, test: test}) do
    invalid_yield_statement?(body) or invalid_yield_expression?(test)
  end

  defp invalid_yield_statement?(%AST.ForStatement{
         init: init,
         test: test,
         update: update,
         body: body
       }) do
    invalid_yield_expression?(init) or invalid_yield_expression?(test) or
      invalid_yield_expression?(update) or
      invalid_yield_statement?(body)
  end

  defp invalid_yield_statement?(%AST.ForInStatement{left: left, right: right, body: body}) do
    invalid_yield_expression?(left) or invalid_yield_expression?(right) or
      invalid_yield_statement?(body)
  end

  defp invalid_yield_statement?(%AST.ForOfStatement{left: left, right: right, body: body}) do
    invalid_yield_expression?(left) or invalid_yield_expression?(right) or
      invalid_yield_statement?(body)
  end

  defp invalid_yield_statement?(%AST.SwitchStatement{discriminant: discriminant, cases: cases}) do
    invalid_yield_expression?(discriminant) or
      Enum.any?(cases, fn switch_case ->
        invalid_yield_expression?(switch_case.test) or
          Enum.any?(switch_case.consequent, &invalid_yield_statement?/1)
      end)
  end

  defp invalid_yield_statement?(%AST.TryStatement{
         block: block,
         handler: handler,
         finalizer: finalizer
       }) do
    invalid_yield_statement?(block) or invalid_yield_statement?(handler) or
      invalid_yield_statement?(finalizer)
  end

  defp invalid_yield_statement?(%AST.CatchClause{body: body}), do: invalid_yield_statement?(body)

  defp invalid_yield_statement?(%AST.LabeledStatement{body: body}),
    do: invalid_yield_statement?(body)

  defp invalid_yield_statement?(_statement), do: false

  defp invalid_yield_expression?(nil), do: false
  defp invalid_yield_expression?(%AST.YieldExpression{}), do: true

  defp invalid_yield_expression?(%AST.UnaryExpression{argument: argument}),
    do: invalid_yield_expression?(argument)

  defp invalid_yield_expression?(%AST.UpdateExpression{argument: argument}),
    do: invalid_yield_expression?(argument)

  defp invalid_yield_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: invalid_yield_expression?(left) or invalid_yield_expression?(right)

  defp invalid_yield_expression?(%AST.LogicalExpression{left: left, right: right}),
    do: invalid_yield_expression?(left) or invalid_yield_expression?(right)

  defp invalid_yield_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: invalid_yield_expression?(left) or invalid_yield_expression?(right)

  defp invalid_yield_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &invalid_yield_expression?/1)

  defp invalid_yield_expression?(%AST.ConditionalExpression{
         test: test,
         consequent: consequent,
         alternate: alternate
       }) do
    invalid_yield_expression?(test) or invalid_yield_expression?(consequent) or
      invalid_yield_expression?(alternate)
  end

  defp invalid_yield_expression?(%AST.CallExpression{callee: callee, arguments: arguments}) do
    invalid_yield_expression?(callee) or Enum.any?(arguments, &invalid_yield_expression?/1)
  end

  defp invalid_yield_expression?(%AST.MemberExpression{
         object: object,
         property: property,
         computed: computed?
       }) do
    invalid_yield_expression?(object) or (computed? and invalid_yield_expression?(property))
  end

  defp invalid_yield_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &invalid_yield_expression?/1)

  defp invalid_yield_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &invalid_yield_expression?/1)

  defp invalid_yield_expression?(%AST.Property{key: key, value: value, computed: computed?}) do
    (computed? and invalid_yield_expression?(key)) or invalid_yield_expression?(value)
  end

  defp invalid_yield_expression?(%AST.SpreadElement{argument: argument}),
    do: invalid_yield_expression?(argument)

  defp invalid_yield_expression?(%AST.FunctionExpression{generator: true}), do: false

  defp invalid_yield_expression?(%AST.FunctionExpression{body: body}),
    do: invalid_yield_statement?(body)

  defp invalid_yield_expression?(%AST.ArrowFunctionExpression{body: body}),
    do: invalid_yield_statement?(body) or invalid_yield_expression?(body)

  defp invalid_yield_expression?(_expression), do: false

  def validate_await_context(state, body) do
    allow_top_level? = state.source_type == :module

    if Enum.any?(body, &invalid_await_statement?(&1, allow_top_level?)) do
      add_error(state, current(state), "await expression not within async function or module")
    else
      state
    end
  end

  defp invalid_await_statement?(%AST.ExpressionStatement{expression: expression}, allow?),
    do: invalid_await_expression?(expression, allow?)

  defp invalid_await_statement?(%AST.ReturnStatement{argument: argument}, allow?),
    do: invalid_await_expression?(argument, allow?)

  defp invalid_await_statement?(%AST.ThrowStatement{argument: argument}, allow?),
    do: invalid_await_expression?(argument, allow?)

  defp invalid_await_statement?(%AST.VariableDeclaration{declarations: declarations}, allow?) do
    Enum.any?(declarations, &invalid_await_expression?(&1.init, allow?))
  end

  defp invalid_await_statement?(%AST.BlockStatement{body: body}, allow?),
    do: Enum.any?(body, &invalid_await_statement?(&1, allow?))

  defp invalid_await_statement?(%AST.FunctionDeclaration{async: true}, _allow?), do: false

  defp invalid_await_statement?(%AST.FunctionDeclaration{body: body}, _allow?),
    do: invalid_await_statement?(body, false)

  defp invalid_await_statement?(
         %AST.IfStatement{test: test, consequent: consequent, alternate: alternate},
         allow?
       ) do
    invalid_await_expression?(test, allow?) or invalid_await_statement?(consequent, allow?) or
      invalid_await_statement?(alternate, allow?)
  end

  defp invalid_await_statement?(%AST.WhileStatement{test: test, body: body}, allow?) do
    invalid_await_expression?(test, allow?) or invalid_await_statement?(body, allow?)
  end

  defp invalid_await_statement?(%AST.DoWhileStatement{body: body, test: test}, allow?) do
    invalid_await_statement?(body, allow?) or invalid_await_expression?(test, allow?)
  end

  defp invalid_await_statement?(
         %AST.ForStatement{init: init, test: test, update: update, body: body},
         allow?
       ) do
    invalid_await_expression?(init, allow?) or invalid_await_expression?(test, allow?) or
      invalid_await_expression?(update, allow?) or invalid_await_statement?(body, allow?)
  end

  defp invalid_await_statement?(%AST.ForInStatement{left: left, right: right, body: body}, allow?) do
    invalid_await_expression?(left, allow?) or invalid_await_expression?(right, allow?) or
      invalid_await_statement?(body, allow?)
  end

  defp invalid_await_statement?(%AST.ForOfStatement{left: left, right: right, body: body}, allow?) do
    invalid_await_expression?(left, allow?) or invalid_await_expression?(right, allow?) or
      invalid_await_statement?(body, allow?)
  end

  defp invalid_await_statement?(
         %AST.SwitchStatement{discriminant: discriminant, cases: cases},
         allow?
       ) do
    invalid_await_expression?(discriminant, allow?) or
      Enum.any?(cases, fn switch_case ->
        invalid_await_expression?(switch_case.test, allow?) or
          Enum.any?(switch_case.consequent, &invalid_await_statement?(&1, allow?))
      end)
  end

  defp invalid_await_statement?(
         %AST.TryStatement{block: block, handler: handler, finalizer: finalizer},
         allow?
       ) do
    invalid_await_statement?(block, allow?) or invalid_await_statement?(handler, allow?) or
      invalid_await_statement?(finalizer, allow?)
  end

  defp invalid_await_statement?(%AST.CatchClause{body: body}, allow?),
    do: invalid_await_statement?(body, allow?)

  defp invalid_await_statement?(%AST.LabeledStatement{body: body}, allow?),
    do: invalid_await_statement?(body, allow?)

  defp invalid_await_statement?(_statement, _allow?), do: false

  defp invalid_await_expression?(nil, _allow?), do: false
  defp invalid_await_expression?(%AST.AwaitExpression{}, true), do: false
  defp invalid_await_expression?(%AST.AwaitExpression{}, false), do: true

  defp invalid_await_expression?(%AST.UnaryExpression{argument: argument}, allow?),
    do: invalid_await_expression?(argument, allow?)

  defp invalid_await_expression?(%AST.UpdateExpression{argument: argument}, allow?),
    do: invalid_await_expression?(argument, allow?)

  defp invalid_await_expression?(%AST.BinaryExpression{left: left, right: right}, allow?),
    do: invalid_await_expression?(left, allow?) or invalid_await_expression?(right, allow?)

  defp invalid_await_expression?(%AST.LogicalExpression{left: left, right: right}, allow?),
    do: invalid_await_expression?(left, allow?) or invalid_await_expression?(right, allow?)

  defp invalid_await_expression?(%AST.AssignmentExpression{left: left, right: right}, allow?),
    do: invalid_await_expression?(left, allow?) or invalid_await_expression?(right, allow?)

  defp invalid_await_expression?(%AST.SequenceExpression{expressions: expressions}, allow?),
    do: Enum.any?(expressions, &invalid_await_expression?(&1, allow?))

  defp invalid_await_expression?(
         %AST.ConditionalExpression{test: test, consequent: consequent, alternate: alternate},
         allow?
       ) do
    invalid_await_expression?(test, allow?) or invalid_await_expression?(consequent, allow?) or
      invalid_await_expression?(alternate, allow?)
  end

  defp invalid_await_expression?(
         %AST.CallExpression{callee: callee, arguments: arguments},
         allow?
       ) do
    invalid_await_expression?(callee, allow?) or
      Enum.any?(arguments, &invalid_await_expression?(&1, allow?))
  end

  defp invalid_await_expression?(
         %AST.MemberExpression{object: object, property: property, computed: computed?},
         allow?
       ) do
    invalid_await_expression?(object, allow?) or
      (computed? and invalid_await_expression?(property, allow?))
  end

  defp invalid_await_expression?(%AST.ArrayExpression{elements: elements}, allow?),
    do: Enum.any?(elements, &invalid_await_expression?(&1, allow?))

  defp invalid_await_expression?(%AST.ObjectExpression{properties: properties}, allow?),
    do: Enum.any?(properties, &invalid_await_expression?(&1, allow?))

  defp invalid_await_expression?(
         %AST.Property{key: key, value: value, computed: computed?},
         allow?
       ) do
    (computed? and invalid_await_expression?(key, allow?)) or
      invalid_await_expression?(value, allow?)
  end

  defp invalid_await_expression?(%AST.SpreadElement{argument: argument}, allow?),
    do: invalid_await_expression?(argument, allow?)

  defp invalid_await_expression?(%AST.FunctionExpression{async: true}, _allow?), do: false

  defp invalid_await_expression?(%AST.FunctionExpression{body: body}, _allow?),
    do: invalid_await_statement?(body, false)

  defp invalid_await_expression?(%AST.ArrowFunctionExpression{async: true}, _allow?), do: false

  defp invalid_await_expression?(%AST.ArrowFunctionExpression{body: body}, _allow?),
    do: invalid_await_statement?(body, false) or invalid_await_expression?(body, false)

  defp invalid_await_expression?(_expression, _allow?), do: false

  def validate_new_target_context(state, body) do
    if Enum.any?(body, &invalid_new_target_statement?/1) do
      add_error(state, current(state), "new.target not allowed outside function")
    else
      state
    end
  end

  defp invalid_new_target_statement?(%AST.ExpressionStatement{expression: expression}),
    do: invalid_new_target_expression?(expression)

  defp invalid_new_target_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &invalid_new_target_expression?(&1.init))
  end

  defp invalid_new_target_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &invalid_new_target_statement?/1)

  defp invalid_new_target_statement?(%AST.FunctionDeclaration{}), do: false
  defp invalid_new_target_statement?(_statement), do: false

  defp invalid_new_target_expression?(nil), do: false

  defp invalid_new_target_expression?(%AST.MetaProperty{
         meta: %AST.Identifier{name: "new"},
         property: %AST.Identifier{name: "target"}
       }),
       do: true

  defp invalid_new_target_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: invalid_new_target_expression?(left) or invalid_new_target_expression?(right)

  defp invalid_new_target_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &invalid_new_target_expression?/1)

  defp invalid_new_target_expression?(%AST.CallExpression{callee: callee, arguments: arguments}),
    do:
      invalid_new_target_expression?(callee) or
        Enum.any?(arguments, &invalid_new_target_expression?/1)

  defp invalid_new_target_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &invalid_new_target_expression?/1)

  defp invalid_new_target_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &invalid_new_target_expression?/1)

  defp invalid_new_target_expression?(%AST.Property{value: value}),
    do: invalid_new_target_expression?(value)

  defp invalid_new_target_expression?(_expression), do: false

  def validate_import_meta_context(%{source_type: :module} = state, _body), do: state

  def validate_import_meta_context(state, body) do
    if Enum.any?(body, &invalid_import_meta_statement?/1) do
      add_error(state, current(state), "import.meta only allowed in modules")
    else
      state
    end
  end

  defp invalid_import_meta_statement?(%AST.ExpressionStatement{expression: expression}),
    do: invalid_import_meta_expression?(expression)

  defp invalid_import_meta_statement?(%AST.ReturnStatement{argument: argument}),
    do: invalid_import_meta_expression?(argument)

  defp invalid_import_meta_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &invalid_import_meta_expression?(&1.init))
  end

  defp invalid_import_meta_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &invalid_import_meta_statement?/1)

  defp invalid_import_meta_statement?(%AST.FunctionDeclaration{body: body}),
    do: invalid_import_meta_statement?(body)

  defp invalid_import_meta_statement?(_statement), do: false

  defp invalid_import_meta_expression?(nil), do: false

  defp invalid_import_meta_expression?(%AST.MetaProperty{
         meta: %AST.Identifier{name: "import"},
         property: %AST.Identifier{name: "meta"}
       }),
       do: true

  defp invalid_import_meta_expression?(%AST.MemberExpression{
         object: object,
         property: property,
         computed: computed?
       }) do
    invalid_import_meta_expression?(object) or
      (computed? and invalid_import_meta_expression?(property))
  end

  defp invalid_import_meta_expression?(%AST.CallExpression{callee: callee, arguments: arguments}),
    do:
      invalid_import_meta_expression?(callee) or
        Enum.any?(arguments, &invalid_import_meta_expression?/1)

  defp invalid_import_meta_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: invalid_import_meta_expression?(left) or invalid_import_meta_expression?(right)

  defp invalid_import_meta_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &invalid_import_meta_expression?/1)

  defp invalid_import_meta_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &invalid_import_meta_expression?/1)

  defp invalid_import_meta_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &invalid_import_meta_expression?/1)

  defp invalid_import_meta_expression?(%AST.Property{value: value}),
    do: invalid_import_meta_expression?(value)

  defp invalid_import_meta_expression?(_expression), do: false

  def validate_super_context(state, body) do
    if Enum.any?(body, &invalid_super_statement?/1) do
      add_error(state, current(state), "super not allowed outside class method")
    else
      state
    end
  end

  defp invalid_super_statement?(%AST.ExpressionStatement{expression: expression}),
    do: invalid_super_expression?(expression)

  defp invalid_super_statement?(%AST.ReturnStatement{argument: argument}),
    do: invalid_super_expression?(argument)

  defp invalid_super_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &invalid_super_expression?(&1.init))
  end

  defp invalid_super_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &invalid_super_statement?/1)

  defp invalid_super_statement?(%AST.FunctionDeclaration{body: body}),
    do: invalid_super_statement?(body)

  defp invalid_super_statement?(%AST.ClassDeclaration{}), do: false
  defp invalid_super_statement?(_statement), do: false

  defp invalid_super_expression?(nil), do: false
  defp invalid_super_expression?(%AST.Identifier{name: "super"}), do: true

  defp invalid_super_expression?(%AST.CallExpression{callee: callee, arguments: arguments}),
    do: invalid_super_expression?(callee) or Enum.any?(arguments, &invalid_super_expression?/1)

  defp invalid_super_expression?(%AST.MemberExpression{
         object: object,
         property: property,
         computed: computed?
       }) do
    invalid_super_expression?(object) or (computed? and invalid_super_expression?(property))
  end

  defp invalid_super_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: invalid_super_expression?(left) or invalid_super_expression?(right)

  defp invalid_super_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &invalid_super_expression?/1)

  defp invalid_super_expression?(%AST.ArrayExpression{elements: elements}),
    do: Enum.any?(elements, &invalid_super_expression?/1)

  defp invalid_super_expression?(%AST.ObjectExpression{properties: properties}),
    do: Enum.any?(properties, &invalid_super_expression?/1)

  defp invalid_super_expression?(%AST.Property{value: value}),
    do: invalid_super_expression?(value)

  defp invalid_super_expression?(_expression), do: false

  def validate_class_super_calls(state, body) do
    if Enum.any?(body, &invalid_class_super_call_statement?/1) do
      add_error(state, current(state), "super call not allowed outside derived constructor")
    else
      state
    end
  end

  defp invalid_class_super_call_statement?(%AST.ClassDeclaration{
         super_class: super_class,
         body: body
       }) do
    Enum.any?(body, &invalid_class_super_call_element?(&1, super_class))
  end

  defp invalid_class_super_call_statement?(_statement), do: false

  defp invalid_class_super_call_element?(
         %AST.MethodDefinition{kind: :constructor, value: value},
         super_class
       ) do
    is_nil(super_class) and has_super_call_statement?(value.body)
  end

  defp invalid_class_super_call_element?(%AST.MethodDefinition{value: value}, _super_class) do
    has_super_call_statement?(value.body)
  end

  defp invalid_class_super_call_element?(%AST.StaticBlock{body: body}, _super_class) do
    Enum.any?(body, &has_super_call_statement?/1)
  end

  defp invalid_class_super_call_element?(%AST.FieldDefinition{value: value}, _super_class) do
    has_super_call_expression?(value)
  end

  defp invalid_class_super_call_element?(_element, _super_class), do: false

  defp has_super_call_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &has_super_call_statement?/1)

  defp has_super_call_statement?(%AST.ExpressionStatement{expression: expression}),
    do: has_super_call_expression?(expression)

  defp has_super_call_statement?(%AST.ReturnStatement{argument: argument}),
    do: has_super_call_expression?(argument)

  defp has_super_call_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &has_super_call_expression?(&1.init))
  end

  defp has_super_call_statement?(_statement), do: false

  defp has_super_call_expression?(nil), do: false

  defp has_super_call_expression?(%AST.CallExpression{callee: %AST.Identifier{name: "super"}}),
    do: true

  defp has_super_call_expression?(%AST.CallExpression{callee: callee, arguments: arguments}),
    do: has_super_call_expression?(callee) or Enum.any?(arguments, &has_super_call_expression?/1)

  defp has_super_call_expression?(%AST.MemberExpression{
         object: object,
         property: property,
         computed: computed?
       }) do
    has_super_call_expression?(object) or (computed? and has_super_call_expression?(property))
  end

  defp has_super_call_expression?(%AST.AssignmentExpression{left: left, right: right}),
    do: has_super_call_expression?(left) or has_super_call_expression?(right)

  defp has_super_call_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &has_super_call_expression?/1)

  defp has_super_call_expression?(_expression), do: false

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
