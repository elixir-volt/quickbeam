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

  defmodule PrivateIdentifier do
    @moduledoc "Private class field or method name."
    defstruct type: :private_identifier, name: nil
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

  defmodule ImportDeclaration do
    @moduledoc "Static ES module import declaration."
    defstruct type: :import_declaration, specifiers: [], source: nil, attributes: nil
  end

  defmodule ImportSpecifier do
    @moduledoc "Named import specifier."
    defstruct type: :import_specifier, imported: nil, local: nil
  end

  defmodule ImportDefaultSpecifier do
    @moduledoc "Default import specifier."
    defstruct type: :import_default_specifier, local: nil
  end

  defmodule ImportNamespaceSpecifier do
    @moduledoc "Namespace import specifier."
    defstruct type: :import_namespace_specifier, local: nil
  end

  defmodule ExportNamedDeclaration do
    @moduledoc "Named ES module export declaration."
    defstruct type: :export_named_declaration,
              declaration: nil,
              specifiers: [],
              source: nil,
              attributes: nil
  end

  defmodule ExportDefaultDeclaration do
    @moduledoc "Default ES module export declaration."
    defstruct type: :export_default_declaration, declaration: nil
  end

  defmodule ExportAllDeclaration do
    @moduledoc "Namespace re-export declaration."
    defstruct type: :export_all_declaration, exported: nil, source: nil, attributes: nil
  end

  defmodule ExportSpecifier do
    @moduledoc "Named export specifier."
    defstruct type: :export_specifier, local: nil, exported: nil
  end

  defmodule ArrayPattern do
    @moduledoc "Array destructuring binding pattern."
    defstruct type: :array_pattern, elements: []
  end

  defmodule ObjectPattern do
    @moduledoc "Object destructuring binding pattern."
    defstruct type: :object_pattern, properties: []
  end

  defmodule RestElement do
    @moduledoc "Rest element in a binding pattern."
    defstruct type: :rest_element, argument: nil
  end

  defmodule AssignmentPattern do
    @moduledoc "Binding pattern element with a default initializer."
    defstruct type: :assignment_pattern, left: nil, right: nil
  end

  defmodule ReturnStatement do
    @moduledoc "Return statement."
    defstruct type: :return_statement, argument: nil
  end

  defmodule ThrowStatement do
    @moduledoc "Throw statement."
    defstruct type: :throw_statement, argument: nil
  end

  defmodule BreakStatement do
    @moduledoc "Break statement with an optional label."
    defstruct type: :break_statement, label: nil
  end

  defmodule ContinueStatement do
    @moduledoc "Continue statement with an optional label."
    defstruct type: :continue_statement, label: nil
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

  defmodule ForStatement do
    @moduledoc "For loop statement."
    defstruct type: :for_statement, init: nil, test: nil, update: nil, body: nil
  end

  defmodule ForInStatement do
    @moduledoc "For-in loop statement."
    defstruct type: :for_in_statement, left: nil, right: nil, body: nil
  end

  defmodule ForOfStatement do
    @moduledoc "For-of loop statement."
    defstruct type: :for_of_statement, left: nil, right: nil, body: nil, await: false
  end

  defmodule DoWhileStatement do
    @moduledoc "Do-while loop statement."
    defstruct type: :do_while_statement, body: nil, test: nil
  end

  defmodule WithStatement do
    @moduledoc "With statement."
    defstruct type: :with_statement, object: nil, body: nil
  end

  defmodule SwitchStatement do
    @moduledoc "Switch statement."
    defstruct type: :switch_statement, discriminant: nil, cases: []
  end

  defmodule SwitchCase do
    @moduledoc "Switch case clause."
    defstruct type: :switch_case, test: nil, consequent: []
  end

  defmodule TryStatement do
    @moduledoc "Try/catch/finally statement."
    defstruct type: :try_statement, block: nil, handler: nil, finalizer: nil
  end

  defmodule CatchClause do
    @moduledoc "Catch clause with an optional binding parameter."
    defstruct type: :catch_clause, param: nil, body: nil
  end

  defmodule EmptyStatement do
    @moduledoc "Empty statement represented by a standalone semicolon."
    defstruct type: :empty_statement
  end

  defmodule DebuggerStatement do
    @moduledoc "Debugger statement."
    defstruct type: :debugger_statement
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

  defmodule ClassDeclaration do
    @moduledoc "Class declaration."
    defstruct type: :class_declaration, id: nil, super_class: nil, body: []
  end

  defmodule ClassExpression do
    @moduledoc "Class expression."
    defstruct type: :class_expression, id: nil, super_class: nil, body: []
  end

  defmodule MethodDefinition do
    @moduledoc "Class method definition."
    defstruct type: :method_definition,
              key: nil,
              value: nil,
              kind: :method,
              static: false,
              computed: false
  end

  defmodule FieldDefinition do
    @moduledoc "Class field definition."
    defstruct type: :field_definition, key: nil, value: nil, static: false, computed: false
  end

  defmodule StaticBlock do
    @moduledoc "Class static initialization block."
    defstruct type: :static_block, body: []
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
    defstruct type: :call_expression, callee: nil, arguments: [], optional: false
  end

  defmodule NewExpression do
    @moduledoc "Constructor call expression created with `new`."
    defstruct type: :new_expression, callee: nil, arguments: []
  end

  defmodule MetaProperty do
    @moduledoc "Meta-property expression such as `import.meta`."
    defstruct type: :meta_property, meta: nil, property: nil
  end

  defmodule TemplateElement do
    @moduledoc "Static segment of a template literal."
    defstruct type: :template_element, value: nil, raw: nil, tail: false
  end

  defmodule TemplateLiteral do
    @moduledoc "Template literal with static quasis and embedded expressions."
    defstruct type: :template_literal, quasis: [], expressions: []
  end

  defmodule TaggedTemplateExpression do
    @moduledoc "Tagged template literal expression."
    defstruct type: :tagged_template_expression, tag: nil, quasi: nil
  end

  defmodule MemberExpression do
    @moduledoc "Property access expression."
    defstruct type: :member_expression,
              object: nil,
              property: nil,
              computed: false,
              optional: false
  end
end
