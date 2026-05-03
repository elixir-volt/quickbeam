defmodule QuickBEAM.JS.BytecodeCompiler do
  @moduledoc """
  Experimental JavaScript AST-to-QuickJS-bytecode compiler.

  This compiler is intentionally separate from `QuickBEAM.VM.Compiler`, which
  lowers existing QuickJS bytecode to BEAM code. This module starts from
  `QuickBEAM.JS.Parser` AST and emits `%QuickBEAM.VM.Bytecode{}` values.
  """

  alias QuickBEAM.JS.BytecodeCompiler.{Assembler, Scope}
  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.VM.Bytecode
  alias QuickBEAM.VM.Bytecode.{Function, VarDef, Writer}

  @ret_name {:predefined, 82}

  @type compile_error :: {:unsupported, term()} | {:parse_error, term()}

  @spec compile(binary() | struct()) :: {:ok, Bytecode.t()} | {:error, compile_error()}
  def compile(source) when is_binary(source) do
    with {:ok, ast} <- parse(source), do: compile(ast)
  end

  def compile(%AST.Program{source_type: :script} = program) do
    with {:ok, fun} <- compile_program(program) do
      atoms = collect_atoms(fun)

      {:ok,
       %Bytecode{
         version: QuickBEAM.VM.Opcodes.bc_version(),
         atoms: atoms,
         value: attach_atoms(fun, atoms)
       }}
    end
  end

  def compile(%AST.Program{source_type: source_type}),
    do: {:error, {:unsupported, {:source_type, source_type}}}

  def compile_to_binary(source) do
    with {:ok, bytecode} <- compile(source), do: Writer.encode(bytecode)
  end

  def compile_to_function(source) do
    with {:ok, %Bytecode{value: value}} <- compile(source), do: {:ok, value}
  end

  defp parse(source) do
    case Parser.parse(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, _program, errors} -> {:error, {:parse_error, errors}}
    end
  end

  defp compile_program(%AST.Program{body: body}) do
    scope = Scope.declare_local(Scope.new(), "<ret>")

    with {:ok, scope} <- declare_program_locals(body, scope),
         {:ok, instructions, constants} <- compile_statements(body, scope, [], []) do
      instructions = finish_program(instructions)

      {:ok,
       build_function(
         name: nil,
         args: [],
         locals: [@ret_name | Enum.drop(scope.local_names, 1)],
         constants: Enum.reverse(constants),
         instructions: instructions,
         has_prototype: false,
         has_simple_parameter_list: false,
         new_target_allowed: false,
         source: ""
       )}
    end
  end

  defp declare_program_locals([], scope), do: {:ok, scope}

  defp declare_program_locals(
         [%AST.VariableDeclaration{declarations: declarations} | rest],
         scope
       ) do
    scope = Enum.reduce(declarations, scope, fn %{id: id}, acc -> declare_pattern(id, acc) end)
    declare_program_locals(rest, scope)
  end

  defp declare_program_locals(
         [%AST.FunctionDeclaration{id: %AST.Identifier{name: name}} | rest],
         scope
       ) do
    declare_program_locals(rest, Scope.declare_local(scope, name))
  end

  defp declare_program_locals([_ | rest], scope), do: declare_program_locals(rest, scope)

  defp declare_pattern(%AST.Identifier{name: name}, scope), do: Scope.declare_local(scope, name)
  defp declare_pattern(_pattern, scope), do: scope

  defp compile_statements([], _scope, instructions, constants), do: {:ok, instructions, constants}

  defp compile_statements([statement], scope, instructions, constants) do
    compile_statement(statement, scope, instructions, constants, tail?: true)
  end

  defp compile_statements([statement | rest], scope, instructions, constants) do
    with {:ok, instructions, constants} <-
           compile_statement(statement, scope, instructions, constants, tail?: false) do
      compile_statements(rest, scope, instructions, constants)
    end
  end

  defp compile_non_tail_statements([], _scope, instructions, constants),
    do: {:ok, instructions, constants}

  defp compile_non_tail_statements([statement | rest], scope, instructions, constants) do
    with {:ok, instructions, constants} <-
           compile_statement(statement, scope, instructions, constants, tail?: false) do
      compile_non_tail_statements(rest, scope, instructions, constants)
    end
  end

  defp compile_statement(
         %AST.ExpressionStatement{
           expression: %AST.AssignmentExpression{
             operator: "=",
             left: %AST.Identifier{name: name},
             right: right
           }
         },
         scope,
         instructions,
         constants,
         opts
       ) do
    with slot when slot != :error <- resolve(scope, name),
         {:ok, instructions, constants} <-
           compile_expression(right, scope, instructions, constants) do
      if Keyword.fetch!(opts, :tail?) do
        {:ok, instructions ++ [write_slot(slot), {:set_loc, 0}], constants}
      else
        {:ok, instructions ++ [put_slot(slot)], constants}
      end
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  defp compile_statement(
         %AST.ExpressionStatement{expression: expression},
         scope,
         instructions,
         constants,
         opts
       ) do
    with {:ok, instructions, constants} <-
           compile_expression(expression, scope, instructions, constants) do
      if Keyword.fetch!(opts, :tail?) do
        {:ok, instructions ++ [{:set_loc, 0}], constants}
      else
        {:ok, instructions ++ [{:put_loc, 0}], constants}
      end
    end
  end

  defp compile_statement(
         %AST.VariableDeclaration{declarations: declarations},
         scope,
         instructions,
         constants,
         _opts
       ) do
    Enum.reduce_while(declarations, {:ok, instructions, constants}, fn declaration,
                                                                       {:ok, ins, consts} ->
      case compile_declarator(declaration, scope, ins, consts) do
        {:ok, ins, consts} -> {:cont, {:ok, ins, consts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_statement(
         %AST.FunctionDeclaration{id: %AST.Identifier{name: name}} = declaration,
         scope,
         instructions,
         constants,
         _opts
       ) do
    with {:ok, function} <- compile_function(declaration, name) do
      case resolve(scope, name) do
        {:loc, loc} ->
          {:ok, instructions ++ [{:closure, length(constants)}, {:put_loc, loc}],
           [function | constants]}

        :error ->
          {:error, {:unsupported, {:unresolved_identifier, name}}}
      end
    end
  end

  defp compile_statement(
         %AST.ReturnStatement{} = statement,
         scope,
         instructions,
         constants,
         _opts
       ) do
    compile_return(statement, scope, instructions, constants)
  end

  defp compile_statement(
         %AST.IfStatement{test: test, consequent: consequent, alternate: alternate},
         scope,
         instructions,
         constants,
         opts
       ) do
    else_label = unique_label(:else)
    end_label = unique_label(:endif)

    with {:ok, instructions, constants} <-
           compile_expression(test, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_statement(
             consequent,
             scope,
             instructions ++ [{:jump_if_false, else_label}],
             constants,
             opts
           ),
         {:ok, instructions, constants} <-
           compile_if_alternate(
             alternate,
             scope,
             instructions ++ [{:jump, end_label}, {:label, else_label}],
             constants,
             opts
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  defp compile_statement(
         %AST.WhileStatement{test: test, body: body},
         scope,
         instructions,
         constants,
         _opts
       ) do
    start_label = unique_label(:while_start)
    end_label = unique_label(:while_end)

    with {:ok, instructions, constants} <-
           compile_expression(test, scope, instructions ++ [{:label, start_label}], constants),
         {:ok, instructions, constants} <-
           compile_statement(
             body,
             scope,
             instructions ++ [{:jump_if_false, end_label}],
             constants,
             tail?: false
           ) do
      {:ok, instructions ++ [{:jump, start_label}, {:label, end_label}], constants}
    end
  end

  defp compile_statement(%AST.BlockStatement{body: body}, scope, instructions, constants, opts) do
    if Keyword.fetch!(opts, :tail?) do
      compile_statements(body, scope, instructions, constants)
    else
      compile_non_tail_statements(body, scope, instructions, constants)
    end
  end

  defp compile_statement(%AST.EmptyStatement{}, _scope, instructions, constants, _opts),
    do: {:ok, instructions, constants}

  defp compile_statement(statement, _scope, _instructions, _constants, _opts),
    do: {:error, {:unsupported, statement.type}}

  defp compile_if_alternate(nil, _scope, instructions, constants, tail?: true),
    do: {:ok, instructions ++ [:undefined, {:set_loc, 0}], constants}

  defp compile_if_alternate(nil, _scope, instructions, constants, _opts),
    do: {:ok, instructions, constants}

  defp compile_if_alternate(alternate, scope, instructions, constants, opts),
    do: compile_statement(alternate, scope, instructions, constants, opts)

  defp compile_declarator(
         %AST.VariableDeclarator{id: %AST.Identifier{name: name}, init: nil},
         scope,
         instructions,
         constants
       ) do
    case resolve(scope, name) do
      {:loc, loc} -> {:ok, instructions ++ [:undefined, {:put_loc, loc}], constants}
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_declarator(
         %AST.VariableDeclarator{id: %AST.Identifier{name: name}, init: init},
         scope,
         instructions,
         constants
       ) do
    with {:loc, loc} <- resolve(scope, name),
         {:ok, instructions, constants} <-
           compile_expression(init, scope, instructions, constants) do
      {:ok, instructions ++ [{:put_loc, loc}], constants}
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  defp compile_return(%AST.ReturnStatement{argument: nil}, _scope, instructions, constants),
    do: {:ok, instructions ++ [:undefined, :return], constants}

  defp compile_return(%AST.ReturnStatement{argument: argument}, scope, instructions, constants) do
    with {:ok, instructions, constants} <-
           compile_expression(argument, scope, instructions, constants) do
      {:ok, instructions ++ [:return], constants}
    end
  end

  defp compile_expression(%AST.Literal{value: value}, _scope, instructions, constants)
       when is_integer(value) do
    {:ok, instructions ++ [{:push_int, value}], constants}
  end

  defp compile_expression(%AST.Literal{value: value}, _scope, instructions, constants)
       when is_float(value) or is_binary(value) do
    {instruction, constants} = add_constant(value, constants)
    {:ok, instructions ++ [instruction], constants}
  end

  defp compile_expression(%AST.Literal{value: nil}, _scope, instructions, constants),
    do: {:ok, instructions ++ [:null], constants}

  defp compile_expression(%AST.Literal{value: true}, _scope, instructions, constants),
    do: {:ok, instructions ++ [true], constants}

  defp compile_expression(%AST.Literal{value: false}, _scope, instructions, constants),
    do: {:ok, instructions ++ [false], constants}

  defp compile_expression(%AST.Identifier{name: name}, scope, instructions, constants) do
    case resolve(scope, name) do
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      slot -> {:ok, instructions ++ [read_slot(slot)], constants}
    end
  end

  defp compile_expression(
         %AST.BinaryExpression{operator: operator, left: left, right: right},
         scope,
         instructions,
         constants
       ) do
    with {:ok, op} <- binary_operator(operator),
         {:ok, instructions, constants} <-
           compile_expression(left, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_expression(right, scope, instructions, constants) do
      {:ok, instructions ++ [op], constants}
    end
  end

  defp compile_expression(
         %AST.UnaryExpression{operator: operator, argument: argument},
         scope,
         instructions,
         constants
       ) do
    with {:ok, op} <- unary_operator(operator),
         {:ok, instructions, constants} <-
           compile_expression(argument, scope, instructions, constants) do
      {:ok, instructions ++ [op], constants}
    end
  end

  defp compile_expression(
         %AST.ConditionalExpression{test: test, consequent: consequent, alternate: alternate},
         scope,
         instructions,
         constants
       ) do
    else_label = unique_label(:cond_else)
    end_label = unique_label(:cond_end)

    with {:ok, instructions, constants} <-
           compile_expression(test, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_expression(
             consequent,
             scope,
             instructions ++ [{:jump_if_false, else_label}],
             constants
           ),
         {:ok, instructions, constants} <-
           compile_expression(
             alternate,
             scope,
             instructions ++ [{:jump, end_label}, {:label, else_label}],
             constants
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  defp compile_expression(
         %AST.AssignmentExpression{
           operator: "=",
           left: %AST.Identifier{name: name},
           right: right
         },
         scope,
         instructions,
         constants
       ) do
    with slot when slot != :error <- resolve(scope, name),
         {:ok, instructions, constants} <-
           compile_expression(right, scope, instructions, constants) do
      {:ok, instructions ++ [write_slot(slot)], constants}
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  defp compile_expression(
         %AST.ArrayExpression{elements: elements},
         scope,
         instructions,
         constants
       ) do
    with {:ok, instructions, constants} <-
           compile_array_elements(elements, scope, instructions, constants) do
      {:ok, instructions ++ [{:array_from, length(elements)}], constants}
    end
  end

  defp compile_expression(
         %AST.MemberExpression{object: object, property: property, computed: true},
         scope,
         instructions,
         constants
       ) do
    with {:ok, instructions, constants} <-
           compile_expression(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_expression(property, scope, instructions, constants) do
      {:ok, instructions ++ [:get_array_el], constants}
    end
  end

  defp compile_expression(
         %AST.MemberExpression{
           object: object,
           property: %AST.Identifier{name: "length"},
           computed: false
         },
         scope,
         instructions,
         constants
       ) do
    with {:ok, instructions, constants} <-
           compile_expression(object, scope, instructions, constants) do
      {:ok, instructions ++ [:get_length], constants}
    end
  end

  defp compile_expression(%AST.FunctionExpression{} = expression, _scope, instructions, constants) do
    with {:ok, function} <- compile_function(expression, function_name(expression.id)) do
      {:ok, instructions ++ [{:closure, length(constants)}], [function | constants]}
    end
  end

  defp compile_expression(
         %AST.CallExpression{callee: callee, arguments: args},
         scope,
         instructions,
         constants
       )
       when length(args) <= 3 do
    with {:ok, instructions, constants} <-
           compile_expression(callee, scope, instructions, constants),
         {:ok, instructions, constants} <- compile_call_args(args, scope, instructions, constants) do
      {:ok, instructions ++ [{:call, length(args)}], constants}
    end
  end

  defp compile_expression(expression, _scope, _instructions, _constants),
    do: {:error, {:unsupported, expression.type}}

  defp compile_array_elements([], _scope, instructions, constants),
    do: {:ok, instructions, constants}

  defp compile_array_elements([nil | rest], _scope, _instructions, _constants),
    do: {:error, {:unsupported, {:array_hole, length(rest)}}}

  defp compile_array_elements([%AST.SpreadElement{} | _rest], _scope, _instructions, _constants),
    do: {:error, {:unsupported, :array_spread}}

  defp compile_array_elements([element | rest], scope, instructions, constants) do
    with {:ok, instructions, constants} <-
           compile_expression(element, scope, instructions, constants) do
      compile_array_elements(rest, scope, instructions, constants)
    end
  end

  defp compile_call_args([], _scope, instructions, constants), do: {:ok, instructions, constants}

  defp compile_call_args([arg | rest], scope, instructions, constants) do
    with {:ok, instructions, constants} <- compile_expression(arg, scope, instructions, constants) do
      compile_call_args(rest, scope, instructions, constants)
    end
  end

  defp compile_function(function, name) do
    params = Enum.map(function.params, &identifier_name!/1)
    scope = Scope.new(params)

    with {:ok, scope} <- declare_program_locals(function.body.body, scope),
         {:ok, instructions, constants} <- compile_statements(function.body.body, scope, [], []) do
      instructions = ensure_function_return(instructions)

      {:ok,
       build_function(
         name: name,
         args: params,
         locals: scope.local_names,
         constants: Enum.reverse(constants),
         instructions: instructions,
         has_prototype: true,
         has_simple_parameter_list: true,
         new_target_allowed: true,
         source: ""
       )}
    end
  end

  defp build_function(opts) do
    instructions = Keyword.fetch!(opts, :instructions)
    byte_code = Assembler.encode(instructions)
    stack_size = Assembler.stack_size(instructions)
    args = Keyword.fetch!(opts, :args)
    locals = Keyword.fetch!(opts, :locals)

    %Function{
      name: Keyword.fetch!(opts, :name),
      filename: "<elixir-bytecode-compiler>",
      line_num: 1,
      col_num: 1,
      arg_count: length(args),
      var_count: length(locals),
      defined_arg_count: length(args),
      stack_size: stack_size,
      locals: Enum.map(args ++ locals, &var_def/1),
      constants: Keyword.fetch!(opts, :constants),
      byte_code: byte_code,
      has_prototype: Keyword.fetch!(opts, :has_prototype),
      has_simple_parameter_list: Keyword.fetch!(opts, :has_simple_parameter_list),
      new_target_allowed: Keyword.fetch!(opts, :new_target_allowed),
      arguments_allowed: true,
      is_strict_mode: false,
      has_debug_info: false,
      source: Keyword.fetch!(opts, :source)
    }
  end

  defp var_def(name) do
    %VarDef{
      name: name,
      scope_level: 0,
      scope_next: 0,
      var_kind: 0,
      is_const: false,
      is_lexical: false,
      is_captured: false
    }
  end

  defp finish_program([]), do: [:undefined, {:set_loc, 0}, :return]
  defp finish_program(instructions), do: instructions ++ [:return]

  defp ensure_function_return([]), do: [:return_undef]

  defp ensure_function_return(instructions) do
    if List.last(instructions) in [:return, :return_undef],
      do: instructions,
      else: instructions ++ [:return_undef]
  end

  defp binary_operator("+"), do: {:ok, :add}
  defp binary_operator("-"), do: {:ok, :sub}
  defp binary_operator("*"), do: {:ok, :mul}
  defp binary_operator("/"), do: {:ok, :div}
  defp binary_operator("%"), do: {:ok, :mod}
  defp binary_operator("<"), do: {:ok, :lt}
  defp binary_operator("<="), do: {:ok, :lte}
  defp binary_operator(">"), do: {:ok, :gt}
  defp binary_operator(">="), do: {:ok, :gte}
  defp binary_operator("=="), do: {:ok, :eq}
  defp binary_operator("!="), do: {:ok, :neq}
  defp binary_operator("==="), do: {:ok, :strict_eq}
  defp binary_operator("!=="), do: {:ok, :strict_neq}
  defp binary_operator(operator), do: {:error, {:unsupported, {:binary_operator, operator}}}

  defp unary_operator("-"), do: {:ok, :neg}
  defp unary_operator("+"), do: {:ok, :plus}
  defp unary_operator("!"), do: {:ok, :lnot}
  defp unary_operator("typeof"), do: {:ok, :typeof}
  defp unary_operator(operator), do: {:error, {:unsupported, {:unary_operator, operator}}}

  defp add_constant(value, constants), do: {{:constant, length(constants)}, [value | constants]}

  defp read_slot({:arg, index}), do: {:get_arg, index}
  defp read_slot({:loc, index}), do: {:get_loc, index}

  defp write_slot({:loc, index}), do: {:set_loc, index}
  defp write_slot({:arg, index}), do: {:set_arg, index}

  defp put_slot({:loc, index}), do: {:put_loc, index}
  defp put_slot({:arg, index}), do: {:put_arg, index}

  defp unique_label(prefix), do: {prefix, System.unique_integer([:positive])}

  defp resolve(scope, name), do: Scope.resolve(scope, name)

  defp identifier_name!(%AST.Identifier{name: name}), do: name

  defp function_name(nil), do: nil
  defp function_name(%AST.Identifier{name: name}), do: name

  defp collect_atoms(%Function{} = function) do
    function
    |> do_collect_atoms([])
    |> Enum.reject(&(match?({:predefined, _}, &1) or is_nil(&1)))
    |> Enum.uniq()
    |> List.to_tuple()
  end

  defp do_collect_atoms(%Function{} = function, acc) do
    acc = [function.name, function.filename | acc]
    acc = Enum.reduce(function.locals, acc, fn %VarDef{name: name}, acc -> [name | acc] end)

    Enum.reduce(function.constants, acc, fn
      %Function{} = inner, acc -> do_collect_atoms(inner, acc)
      value, acc when is_binary(value) -> [value | acc]
      _value, acc -> acc
    end)
  end

  defp attach_atoms(%Function{} = function, atoms) do
    function
    |> Map.put(:atoms, atoms)
    |> Map.update!(:constants, &attach_constant_atoms(&1, atoms))
  end

  defp attach_constant_atoms(constants, atoms) do
    for constant <- constants do
      if match?(%Function{}, constant), do: attach_atoms(constant, atoms), else: constant
    end
  end
end
