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

  defmodule EmptyStatement do
    @moduledoc "Empty statement represented by a standalone semicolon."
    defstruct type: :empty_statement
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
