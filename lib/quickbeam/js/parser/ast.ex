defmodule QuickBEAM.JS.Parser.AST do
  @moduledoc "AST node structs emitted by the JavaScript parser."

  defmodule Program do
    @moduledoc "JavaScript script or module program."
    defstruct type: :program, source_type: :script, body: []
  end

  defmodule Identifier do
    @moduledoc "Identifier reference or binding name."
    defstruct type: :identifier, name: nil
  end

  defmodule Literal do
    @moduledoc "Literal value such as a number, string, boolean, or null."
    defstruct type: :literal, value: nil, raw: nil
  end

  defmodule ExpressionStatement do
    @moduledoc "Statement wrapping an expression."
    defstruct type: :expression_statement, expression: nil
  end

  defmodule VariableDeclaration do
    @moduledoc "Variable declaration statement."
    defstruct type: :variable_declaration, kind: nil, declarations: []
  end

  defmodule VariableDeclarator do
    @moduledoc "One declarator in a variable declaration."
    defstruct type: :variable_declarator, id: nil, init: nil
  end

  defmodule ReturnStatement do
    @moduledoc "Return statement."
    defstruct type: :return_statement, argument: nil
  end

  defmodule BreakStatement do
    @moduledoc "Break statement with an optional label."
    defstruct type: :break_statement, label: nil
  end

  defmodule LabeledStatement do
    @moduledoc "Labeled statement."
    defstruct type: :labeled_statement, label: nil, body: nil
  end

  defmodule IfStatement do
    @moduledoc "If statement."
    defstruct type: :if_statement, test: nil, consequent: nil, alternate: nil
  end

  defmodule WhileStatement do
    @moduledoc "While loop statement."
    defstruct type: :while_statement, test: nil, body: nil
  end

  defmodule DoWhileStatement do
    @moduledoc "Do-while loop statement."
    defstruct type: :do_while_statement, body: nil, test: nil
  end

  defmodule WithStatement do
    @moduledoc "With statement."
    defstruct type: :with_statement, object: nil, body: nil
  end

  defmodule EmptyStatement do
    @moduledoc "Empty statement represented by a standalone semicolon."
    defstruct type: :empty_statement
  end

  defmodule BlockStatement do
    @moduledoc "Block statement containing a statement list."
    defstruct type: :block_statement, body: []
  end

  defmodule FunctionDeclaration do
    @moduledoc "Function declaration."
    defstruct type: :function_declaration,
              id: nil,
              params: [],
              body: nil,
              async: false,
              generator: false
  end

  defmodule FunctionExpression do
    @moduledoc "Function expression."
    defstruct type: :function_expression,
              id: nil,
              params: [],
              body: nil,
              async: false,
              generator: false
  end

  defmodule ArrayExpression do
    @moduledoc "Array literal expression."
    defstruct type: :array_expression, elements: []
  end

  defmodule ObjectExpression do
    @moduledoc "Object literal expression."
    defstruct type: :object_expression, properties: []
  end

  defmodule Property do
    @moduledoc "Object literal property."
    defstruct type: :property,
              key: nil,
              value: nil,
              kind: :init,
              method: false,
              shorthand: false,
              computed: false
  end

  defmodule SpreadElement do
    @moduledoc "Spread element in array literals or call arguments."
    defstruct type: :spread_element, argument: nil
  end

  defmodule ArrowFunctionExpression do
    @moduledoc "Arrow function expression."
    defstruct type: :arrow_function_expression, params: [], body: nil, async: false
  end

  defmodule YieldExpression do
    @moduledoc "Yield expression."
    defstruct type: :yield_expression, argument: nil, delegate: false
  end

  defmodule AwaitExpression do
    @moduledoc "Await expression."
    defstruct type: :await_expression, argument: nil
  end

  defmodule BinaryExpression do
    @moduledoc "Binary operator expression."
    defstruct type: :binary_expression, operator: nil, left: nil, right: nil
  end

  defmodule LogicalExpression do
    @moduledoc "Logical operator expression."
    defstruct type: :logical_expression, operator: nil, left: nil, right: nil
  end

  defmodule AssignmentExpression do
    @moduledoc "Assignment operator expression."
    defstruct type: :assignment_expression, operator: nil, left: nil, right: nil
  end

  defmodule UnaryExpression do
    @moduledoc "Unary operator expression."
    defstruct type: :unary_expression, operator: nil, argument: nil, prefix: true
  end

  defmodule UpdateExpression do
    @moduledoc "Prefix or postfix update expression."
    defstruct type: :update_expression, operator: nil, argument: nil, prefix: true
  end

  defmodule ConditionalExpression do
    @moduledoc "Ternary conditional expression."
    defstruct type: :conditional_expression, test: nil, consequent: nil, alternate: nil
  end

  defmodule SequenceExpression do
    @moduledoc "Comma sequence expression."
    defstruct type: :sequence_expression, expressions: []
  end

  defmodule CallExpression do
    @moduledoc "Function or method call expression."
    defstruct type: :call_expression, callee: nil, arguments: []
  end

  defmodule MemberExpression do
    @moduledoc "Property access expression."
    defstruct type: :member_expression, object: nil, property: nil, computed: false
  end
end
