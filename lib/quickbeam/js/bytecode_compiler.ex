defmodule QuickBEAM.JS.BytecodeCompiler do
  @moduledoc """
  Experimental JavaScript AST-to-QuickJS-bytecode compiler.

  This compiler is intentionally separate from `QuickBEAM.VM.Compiler`, which
  lowers existing QuickJS bytecode to BEAM code. This module starts from
  `QuickBEAM.JS.Parser` AST and emits `%QuickBEAM.VM.Bytecode{}` values.
  """

  alias QuickBEAM.JS.BytecodeCompiler.{
    Declarations,
    Emitter,
    Expressions,
    FunctionBuilder,
    Scope,
    Statements
  }

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.VM.Bytecode
  alias QuickBEAM.VM.Bytecode.Writer

  @ret_name {:predefined, 82}

  @type compile_error :: {:unsupported, term()} | {:parse_error, term()}

  @spec compile(binary() | struct()) :: {:ok, Bytecode.t()} | {:error, compile_error()}
  def compile(source) when is_binary(source) do
    with {:ok, ast} <- parse(source), do: compile(ast)
  end

  def compile(%AST.Program{source_type: :script} = program) do
    with {:ok, fun} <- compile_program(program) do
      atoms = FunctionBuilder.collect_atoms(fun)

      {:ok,
       %Bytecode{
         version: QuickBEAM.VM.Opcodes.bc_version(),
         atoms: atoms,
         value: FunctionBuilder.attach_atoms(fun, atoms)
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

    with {:ok, scope} <- Declarations.declare_program_locals(body, scope),
         {:ok, instructions, constants} <-
           compile_statements(body, scope, [], [], top_level_globals(scope)) do
      instructions = finish_program(instructions)

      {:ok,
       FunctionBuilder.build(
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

  defp compile_statements(statements, scope, instructions, constants, globals) do
    Statements.compile_all(
      statements,
      Emitter.new(scope, instructions, constants, callbacks(globals))
    )
  end

  defp compile_function_body(statements, scope, instructions, constants, globals) do
    Statements.compile_non_tail(
      statements,
      Emitter.new(scope, instructions, constants, callbacks(globals))
    )
  end

  defp compile_expression(expression, scope, instructions, constants, globals) do
    Expressions.compile(
      expression,
      Emitter.new(scope, instructions, constants, callbacks(globals))
    )
  end

  defp compile_function(function, name, globals) do
    case compile_function_full(function, name, globals) do
      {:ok, _} = ok -> ok
      {:error, reason} -> maybe_stub(reason, function, name)
    end
  end

  defp maybe_stub({:unsupported, reason}, function, name)
       when reason in [
              :with_statement,
              :yield_expression,
              :await_expression,
              :for_of_statement,
              :class_constructor_body
            ],
       do: compile_function_stub(function, name)

  defp maybe_stub({:unsupported, {:unresolved_identifier, "import"}}, function, name),
    do: compile_function_stub(function, name)

  defp maybe_stub(error, _function, _name), do: {:error, error}

  defp compile_function_full(function, name, globals) do
    {params, defaults, rest_param, pattern_params} = normalize_params(function.params)
    scope = Scope.new(params, globals)
    scope = declare_param_patterns(scope, pattern_params)

    with {:ok, scope} <- Declarations.declare_program_locals(function.body.body, scope),
         {:ok, instructions, constants} <- compile_param_patterns(pattern_params, scope, [], []),
         {:ok, instructions, constants} <- compile_rest_param(rest_param, instructions, constants),
         {:ok, instructions, constants} <-
           compile_param_defaults(defaults, scope, instructions, constants, globals),
         {:ok, instructions, constants} <-
           compile_function_body(function.body.body, scope, instructions, constants, globals) do
      instructions = ensure_function_return(instructions)

      {:ok,
       FunctionBuilder.build(
         name: name,
         args: params,
         locals: scope.local_names,
         constants: Enum.reverse(constants),
         instructions: instructions,
         defined_arg_count: defined_arg_count(params, rest_param),
         has_prototype: true,
         has_simple_parameter_list: defaults == [] and rest_param == nil,
         new_target_allowed: true,
         source: ""
       )}
    end
  end

  defp compile_function_stub(_function, name) do
    {:ok,
     FunctionBuilder.build(
       name: name,
       args: [],
       locals: [],
       constants: [],
       instructions: [:return_undef],
       defined_arg_count: 0,
       has_prototype: true,
       has_simple_parameter_list: true,
       new_target_allowed: true,
       source: ""
     )}
  end

  defp finish_program([]), do: [:undefined, {:set_loc, 0}, :return]
  defp finish_program(instructions), do: instructions ++ [:return]

  defp ensure_function_return([]), do: [:return_undef]

  defp ensure_function_return(instructions) do
    if List.last(instructions) in [:return, :return_undef],
      do: instructions,
      else: instructions ++ [:return_undef]
  end

  defp callbacks(globals) do
    %{
      compile_expression: fn expression, scope, instructions, constants ->
        compile_expression(expression, scope, instructions, constants, globals)
      end,
      compile_function: fn function, name -> compile_function(function, name, globals) end,
      resolve: &resolve/2,
      unique_label: &unique_label/1
    }
  end

  defp unique_label(prefix), do: {prefix, System.unique_integer([:positive])}

  defp resolve(scope, name), do: Scope.resolve(scope, name)

  defp top_level_globals(scope), do: Enum.drop(scope.local_names, 1)

  defp normalize_params(params) do
    Enum.reduce(params, {[], [], nil, []}, fn
      %AST.Identifier{name: name}, {names, defaults, nil, patterns} ->
        {names ++ [name], defaults, nil, patterns}

      %AST.AssignmentPattern{left: %AST.Identifier{name: name}, right: default},
      {names, defaults, nil, patterns} ->
        {names ++ [name], defaults ++ [{name, default}], nil, patterns}

      %AST.RestElement{argument: %AST.Identifier{name: name}}, {names, defaults, nil, patterns} ->
        {names ++ [name], defaults, {length(names), length(names)}, patterns}

      %AST.ObjectPattern{} = pattern, {names, defaults, nil, patterns} ->
        name = synthetic_param_name(length(names))
        {names ++ [name], defaults, nil, patterns ++ [{length(names), name, pattern}]}

      %AST.ArrayPattern{} = pattern, {names, defaults, nil, patterns} ->
        name = synthetic_param_name(length(names))
        {names ++ [name], defaults, nil, patterns ++ [{length(names), name, pattern}]}

      param, _acc ->
        raise FunctionClauseError, function: :identifier_name!, arity: 1, args: [param]
    end)
  end

  defp synthetic_param_name(index), do: "<param:#{index}>"

  defp defined_arg_count(params, nil), do: length(params)
  defp defined_arg_count(_params, {start, _index}), do: start

  defp declare_param_patterns(scope, pattern_params) do
    Enum.reduce(pattern_params, scope, fn {_index, _name, pattern}, scope ->
      pattern
      |> pattern_names()
      |> Enum.reduce(scope, &Scope.declare_local(&2, &1))
    end)
  end

  defp pattern_names(%AST.ObjectPattern{properties: properties}) do
    Enum.flat_map(properties, fn
      %AST.Property{value: value} -> pattern_names(value)
      _property -> []
    end)
  end

  defp pattern_names(%AST.ArrayPattern{elements: elements}) do
    elements
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&pattern_names/1)
  end

  defp pattern_names(%AST.Identifier{name: name}), do: [name]
  defp pattern_names(_pattern), do: []

  defp compile_param_patterns([], _scope, instructions, constants),
    do: {:ok, instructions, constants}

  defp compile_param_patterns([{index, _name, pattern} | rest], scope, instructions, constants) do
    with {:ok, instructions, constants} <-
           compile_param_pattern(pattern, {:arg, index}, scope, instructions, constants) do
      compile_param_patterns(rest, scope, instructions, constants)
    end
  end

  defp compile_param_pattern(
         %AST.ObjectPattern{properties: properties},
         slot,
         scope,
         instructions,
         constants
       ) do
    Enum.reduce_while(properties, {:ok, instructions, constants}, fn
      %AST.Property{
        computed: false,
        key: %AST.Identifier{name: key},
        value: %AST.Identifier{name: name}
      },
      {:ok, instructions, constants} ->
        case Scope.resolve(scope, name) do
          {:loc, loc} ->
            {:cont,
             {:ok,
              instructions ++
                [
                  QuickBEAM.JS.BytecodeCompiler.Slots.read(slot),
                  {:get_field, key},
                  {:put_loc, loc}
                ], constants}}

          :error ->
            {:halt, {:error, {:unsupported, {:unresolved_identifier, name}}}}
        end

      _property, {:ok, _instructions, _constants} ->
        {:halt, {:error, {:unsupported, :destructured_parameter}}}
    end)
  end

  defp compile_param_pattern(
         %AST.ArrayPattern{elements: elements},
         slot,
         scope,
         instructions,
         constants
       ) do
    elements
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, instructions, constants}, fn
      {nil, _index}, {:ok, instructions, constants} ->
        {:cont, {:ok, instructions, constants}}

      {%AST.Identifier{name: name}, index}, {:ok, instructions, constants} ->
        case Scope.resolve(scope, name) do
          {:loc, loc} ->
            {:cont,
             {:ok,
              instructions ++
                [
                  QuickBEAM.JS.BytecodeCompiler.Slots.read(slot),
                  {:push_int, index},
                  :get_array_el,
                  {:put_loc, loc}
                ], constants}}

          :error ->
            {:halt, {:error, {:unsupported, {:unresolved_identifier, name}}}}
        end

      {_element, _index}, {:ok, _instructions, _constants} ->
        {:halt, {:error, {:unsupported, :destructured_parameter}}}
    end)
  end

  defp compile_rest_param(nil, instructions, constants), do: {:ok, instructions, constants}

  defp compile_rest_param({start, index}, instructions, constants) do
    {:ok,
     instructions ++ [{:rest, start}, QuickBEAM.JS.BytecodeCompiler.Slots.put({:arg, index})],
     constants}
  end

  defp compile_param_defaults([], _scope, instructions, constants, _globals),
    do: {:ok, instructions, constants}

  defp compile_param_defaults([{name, default} | rest], scope, instructions, constants, globals) do
    end_label = unique_label(:default_param_end)
    slot = Scope.resolve(scope, name)

    with {:ok, instructions, constants} <-
           compile_expression(
             default,
             scope,
             instructions ++
               [
                 QuickBEAM.JS.BytecodeCompiler.Slots.read(slot),
                 :undefined,
                 :strict_eq,
                 {:jump_if_false, end_label}
               ],
             constants,
             globals
           ) do
      compile_param_defaults(
        rest,
        scope,
        instructions ++ [QuickBEAM.JS.BytecodeCompiler.Slots.put(slot), {:label, end_label}],
        constants,
        globals
      )
    end
  end
end
