defmodule QuickBEAM.JS.Parser.Validation.Strict.Helpers do
  @moduledoc false

  alias QuickBEAM.JS.Parser.AST

  def program_binding_names(body), do: Enum.flat_map(body, &statement_binding_names/1)

  def statement_binding_names(%AST.ExpressionStatement{expression: expression}),
    do: expression_binding_names(expression)

  def statement_binding_names(%AST.ReturnStatement{argument: argument}),
    do: expression_binding_names(argument)

  def statement_binding_names(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.flat_map(declarations, fn declaration ->
      binding_names(declaration.id) ++ expression_binding_names(declaration.init)
    end)
  end

  def statement_binding_names(%AST.FunctionDeclaration{
        id: %AST.Identifier{name: name},
        body: %AST.BlockStatement{body: body}
      }),
      do: [name | program_binding_names(body)]

  def statement_binding_names(%AST.ClassDeclaration{id: %AST.Identifier{name: name}}), do: [name]
  def statement_binding_names(%AST.BlockStatement{body: body}), do: program_binding_names(body)

  def statement_binding_names(%AST.IfStatement{consequent: consequent, alternate: alternate}) do
    statement_binding_names(consequent) ++ statement_binding_names(alternate)
  end

  def statement_binding_names(%AST.WhileStatement{body: body}), do: statement_binding_names(body)

  def statement_binding_names(%AST.DoWhileStatement{body: body}),
    do: statement_binding_names(body)

  def statement_binding_names(%AST.ForStatement{init: init, body: body}),
    do: binding_names_from_for_init(init) ++ statement_binding_names(body)

  def statement_binding_names(%AST.ForInStatement{left: left, body: body}),
    do: binding_names_from_for_init(left) ++ statement_binding_names(body)

  def statement_binding_names(%AST.ForOfStatement{left: left, body: body}),
    do: binding_names_from_for_init(left) ++ statement_binding_names(body)

  def statement_binding_names(%AST.WithStatement{body: body}), do: statement_binding_names(body)

  def statement_binding_names(%AST.SwitchStatement{cases: cases}) do
    Enum.flat_map(cases, &program_binding_names(&1.consequent))
  end

  def statement_binding_names(%AST.TryStatement{
        block: block,
        handler: handler,
        finalizer: finalizer
      }) do
    statement_binding_names(block) ++
      catch_binding_names(handler) ++ statement_binding_names(finalizer)
  end

  def statement_binding_names(_statement), do: []

  def expression_binding_names(nil), do: []

  def expression_binding_names(%AST.FunctionExpression{body: %AST.BlockStatement{body: body}}),
    do: program_binding_names(body)

  def expression_binding_names(%AST.ArrowFunctionExpression{
        body: %AST.BlockStatement{body: body}
      }),
      do: program_binding_names(body)

  def expression_binding_names(%AST.ArrowFunctionExpression{body: body}),
    do: expression_binding_names(body)

  def expression_binding_names(%AST.AssignmentExpression{left: left, right: right}),
    do: expression_binding_names(left) ++ expression_binding_names(right)

  def expression_binding_names(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.flat_map(expressions, &expression_binding_names/1)

  def expression_binding_names(%AST.CallExpression{callee: callee, arguments: arguments}),
    do: expression_binding_names(callee) ++ Enum.flat_map(arguments, &expression_binding_names/1)

  def expression_binding_names(%AST.MemberExpression{
        object: object,
        property: property,
        computed: computed?
      }) do
    expression_binding_names(object) ++
      if(computed?, do: expression_binding_names(property), else: [])
  end

  def expression_binding_names(%AST.ObjectExpression{properties: properties}),
    do: Enum.flat_map(properties, &expression_binding_names/1)

  def expression_binding_names(%AST.ArrayExpression{elements: elements}),
    do: Enum.flat_map(elements, &expression_binding_names/1)

  def expression_binding_names(%AST.Property{key: key, value: value, computed: computed?}) do
    expression_binding_names(value) ++ if(computed?, do: expression_binding_names(key), else: [])
  end

  def expression_binding_names(%AST.SpreadElement{argument: argument}),
    do: expression_binding_names(argument)

  def expression_binding_names(_expression), do: []

  def binding_names_from_for_init(%AST.VariableDeclaration{} = declaration),
    do: statement_binding_names(declaration)

  def binding_names_from_for_init(_init), do: []

  def catch_binding_names(%AST.CatchClause{param: nil, body: body}),
    do: statement_binding_names(body)

  def catch_binding_names(%AST.CatchClause{param: param, body: body}),
    do: binding_names(param) ++ statement_binding_names(body)

  def catch_binding_names(_handler), do: []

  def body_contains_name?(statements, name) do
    Enum.any?(statements, &statement_contains_name?(&1, name))
  end

  def statement_contains_name?(%AST.VariableDeclaration{declarations: declarations}, name),
    do: Enum.any?(declarations, &(name in binding_names(&1.id)))

  def statement_contains_name?(
        %AST.FunctionDeclaration{id: %AST.Identifier{name: identifier}},
        name
      ),
      do: identifier == name

  def statement_contains_name?(
        %AST.LabeledStatement{label: %AST.Identifier{name: identifier}},
        name
      ),
      do: identifier == name

  def statement_contains_name?(%AST.BlockStatement{body: body}, name),
    do: body_contains_name?(body, name)

  def statement_contains_name?(_statement, _name), do: false

  def strict_directive_body?([
        %AST.ExpressionStatement{expression: %AST.Literal{value: "use strict"}} | _rest
      ]),
      do: true

  def strict_directive_body?([
        %AST.ExpressionStatement{expression: %AST.Literal{value: value}} | rest
      ])
      when is_binary(value),
      do: strict_directive_body?(rest)

  def strict_directive_body?(_body), do: false

  def restricted_strict_name?(name) do
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

  def duplicate_param_names?(params) do
    names = identifier_param_names(params)
    length(names) != length(Enum.uniq(names))
  end

  def identifier_param_names(params), do: Enum.flat_map(params, &binding_names/1)

  def binding_names(%AST.Identifier{name: name}), do: [name]
  def binding_names(%AST.AssignmentPattern{left: left}), do: binding_names(left)
  def binding_names(%AST.RestElement{argument: argument}), do: binding_names(argument)

  def binding_names(%AST.ArrayPattern{elements: elements}),
    do: Enum.flat_map(elements, &binding_names/1)

  def binding_names(%AST.ObjectPattern{properties: properties}),
    do: Enum.flat_map(properties, &binding_names/1)

  def binding_names(%AST.Property{value: value}), do: binding_names(value)
  def binding_names(list) when is_list(list), do: Enum.flat_map(list, &binding_names/1)
  def binding_names(nil), do: []
  def binding_names(_param), do: []

  def contains_yield_expression?(%AST.YieldExpression{}), do: true
  def contains_yield_expression?(%AST.Identifier{name: "yield"}), do: true

  def contains_yield_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: contains_yield_expression?(left) or contains_yield_expression?(right)

  def contains_yield_expression?(%AST.AssignmentPattern{right: right}),
    do: contains_yield_expression?(right)

  def contains_yield_expression?(%AST.ArrayPattern{elements: elements}),
    do: Enum.any?(elements, &contains_yield_expression?/1)

  def contains_yield_expression?(%AST.ObjectPattern{properties: properties}),
    do: Enum.any?(properties, &contains_yield_expression?/1)

  def contains_yield_expression?(%AST.Property{value: value}),
    do: contains_yield_expression?(value)

  def contains_yield_expression?(%AST.RestElement{argument: argument}),
    do: contains_yield_expression?(argument)

  def contains_yield_expression?(_param), do: false

  def contains_await_identifier?(%AST.Identifier{name: "await"}), do: true

  def contains_await_identifier?(%AST.AssignmentPattern{right: right}),
    do: contains_await_identifier?(right)

  def contains_await_identifier?(%AST.ArrayPattern{elements: elements}),
    do: Enum.any?(elements, &contains_await_identifier?/1)

  def contains_await_identifier?(%AST.ObjectPattern{properties: properties}),
    do: Enum.any?(properties, &contains_await_identifier?/1)

  def contains_await_identifier?(%AST.Property{value: value}),
    do: contains_await_identifier?(value)

  def contains_await_identifier?(%AST.RestElement{argument: argument}),
    do: contains_await_identifier?(argument)

  def contains_await_identifier?(_param), do: false

  def contains_await_expression?(%AST.AwaitExpression{}), do: true
  def contains_await_expression?(%AST.Identifier{name: "await"}), do: true

  def contains_await_expression?(%AST.AssignmentPattern{right: right}),
    do: contains_await_expression?(right)

  def contains_await_expression?(%AST.ArrayPattern{elements: elements}),
    do: Enum.any?(elements, &contains_await_expression?/1)

  def contains_await_expression?(%AST.ObjectPattern{properties: properties}),
    do: Enum.any?(properties, &contains_await_expression?/1)

  def contains_await_expression?(%AST.Property{value: value}),
    do: contains_await_expression?(value)

  def contains_await_expression?(%AST.RestElement{argument: argument}),
    do: contains_await_expression?(argument)

  def contains_await_expression?(_param), do: false
end
