defmodule QuickBEAM.JS.Compiler do
  @moduledoc """
  Experimental JavaScript AST-to-QuickBEAM VM instruction compiler.

  This compiler is intentionally separate from `QuickBEAM.VM.Compiler`, which
  lowers VM instructions to BEAM code. This module starts from
  `QuickBEAM.JS.Parser` AST and emits VM functions with pre-resolved
  instructions, not materialized QuickJS bytecode binaries.
  """

  alias QuickBEAM.JS.Compiler.{
    Declarations,
    Emitter,
    Expressions,
    FunctionBuilder,
    Scope,
    Statements
  }

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.VM.Program

  @type compile_error :: {:unsupported, term()} | {:parse_error, term()}

  @spec compile(binary() | struct()) :: {:ok, Program.t()} | {:error, compile_error()}
  def compile(source) when is_binary(source) do
    with {:ok, ast} <- parse(source), do: compile(ast)
  end

  def compile(%AST.Program{source_type: :script} = program) do
    with {:ok, fun} <- compile_program(program) do
      atoms = FunctionBuilder.collect_atoms(fun)

      {:ok,
       %Program{
         version: QuickBEAM.VM.Opcodes.bc_version(),
         atoms: atoms,
         value: FunctionBuilder.attach_atoms(fun, atoms)
       }}
    end
  end

  def compile(%AST.Program{source_type: source_type}),
    do: {:error, {:unsupported, {:source_type, source_type}}}

  def compile_to_function(source) do
    with {:ok, %Program{value: value}} <- compile(source), do: {:ok, value}
  end

  defp parse(source) do
    case Parser.parse(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, _program, errors} -> {:error, {:parse_error, errors}}
    end
  end

  defp compile_program(%AST.Program{body: body}) do
    scope = Scope.declare_local(Scope.new(), "<ret>")
    previous_top_level_function_names = Process.get(:compiler_top_level_function_names)
    previous_block_scopes = Process.get(:compiler_block_scopes)
    previous_block_scope_id = Process.get(:compiler_block_scope_declaration_id)
    previous_var_refs = Process.get(:compiler_var_refs)
    Process.put(:compiler_top_level_function_names, top_level_function_names(body))
    Process.put(:compiler_block_scopes, [])
    Process.put(:compiler_block_scope_declaration_id, 0)
    Process.put(:compiler_var_refs, %{})

    try do
      with {:ok, scope} <- Declarations.declare_program_locals(body, scope),
           {:ok, instructions, constants} <-
             compile_statements(body, scope, [], [], top_level_globals(scope)) do
        instructions = finish_program(instructions)
        var_refs = Process.get(:compiler_var_refs) || %{}
        local_names = scope.local_names

        {local_defs, var_ref_count} =
          if map_size(var_refs) > 0 do
            build_local_defs(local_names, var_refs)
          else
            {nil, 0}
          end

        build_opts =
          [
            name: nil,
            args: [],
            locals: local_names,
            var_ref_count: var_ref_count,
            constants: Enum.reverse(constants),
            instructions: instructions,
            has_prototype: false,
            has_simple_parameter_list: false,
            new_target_allowed: false,
            source: ""
          ] ++ if(local_defs, do: [local_defs: local_defs], else: [])

        {:ok, FunctionBuilder.build(build_opts)}
      end
    after
      restore_process_value(:compiler_top_level_function_names, previous_top_level_function_names)
      restore_process_value(:compiler_block_scopes, previous_block_scopes)
      restore_process_value(:compiler_block_scope_declaration_id, previous_block_scope_id)
      restore_process_value(:compiler_var_refs, previous_var_refs)
    end
  end

  defp top_level_function_names(body) do
    body
    |> Enum.flat_map(fn
      %AST.FunctionDeclaration{id: %AST.Identifier{name: name}} -> [name]
      _ -> []
    end)
    |> MapSet.new()
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
    try do
      case compile_function_full(function, name, globals) do
        {:ok, _} = ok -> ok
        {:error, reason} -> maybe_stub(reason, function, name)
      end
    rescue
      _ -> compile_function_stub(function, name)
    end
  end

  defp maybe_stub({:unsupported, _reason}, function, name),
    do: compile_function_stub(function, name)

  defp maybe_stub({:parse_error, _}, function, name),
    do: compile_function_stub(function, name)

  defp maybe_stub(error, _function, _name), do: {:error, error}

  defp compile_function_full(function, name, globals) do
    {params, defaults, rest_param, pattern_params} = normalize_params(function.params)

    previous_block_scopes = Process.get(:compiler_block_scopes)
    previous_block_scope_id = Process.get(:compiler_block_scope_declaration_id)
    Process.put(:compiler_block_scopes, [])
    Process.put(:compiler_block_scope_declaration_id, 0)

    self_capture_names = Process.get(:compiler_self_capture_names) || MapSet.new()
    Process.delete(:compiler_self_capture_names)

    scope =
      params
      |> Scope.new(globals)
      |> then(fn scope ->
        Enum.reduce(self_capture_names, scope, &Scope.with_self_binding(&2, &1))
      end)

    self_binding_name = function_self_binding_name(function)

    scope =
      if self_binding_name,
        do:
          scope
          |> Scope.declare_local(self_binding_name)
          |> Scope.with_self_binding(self_binding_name),
        else: scope

    scope =
      function
      |> eval_declared_names()
      |> Enum.reduce(scope, &Scope.declare_local(&2, &1))

    scope = declare_param_patterns(scope, pattern_params)
    uses_arguments? = references_arguments?([function.body | function.params])
    has_params? = function.params != []

    lexical_arguments? =
      match?(%AST.ArrowFunctionExpression{}, function) or
        function.type == :arrow_function_expression

    uses_arguments_object? = uses_arguments? and not lexical_arguments?
    scope = if uses_arguments_object?, do: Scope.declare_local(scope, "<arguments>"), else: scope

    scope =
      if uses_arguments? and has_params?,
        do: Scope.with_arguments_alias(scope, length(params)),
        else: scope

    closure_scope = Process.get(:compiler_closure_scope)
    Process.delete(:compiler_closure_scope)
    class_priv = Process.get(:compiler_class_private_scope)
    priv_refs = if class_priv, do: elem(class_priv, 0), else: %{}
    merged_refs = Map.merge(priv_refs, closure_scope || %{})
    scope = if merged_refs != %{}, do: Scope.with_var_refs(scope, merged_refs), else: scope

    prev_var_refs = Process.get(:compiler_var_refs)
    Process.put(:compiler_var_refs, %{})

    prev_self_bindings = Process.get(:compiler_current_self_bindings)

    current_self_bindings =
      if self_binding_name,
        do: MapSet.put(self_capture_names, self_binding_name),
        else: self_capture_names

    strict_self_binding? = self_binding_name != nil and strict_body?(function.body.body)
    prev_strict_self_bindings = Process.get(:compiler_strict_self_bindings)

    if strict_self_binding?,
      do: Process.put(:compiler_strict_self_bindings, current_self_bindings),
      else: Process.delete(:compiler_strict_self_bindings)

    Process.put(:compiler_current_self_bindings, current_self_bindings)

    try do
      body =
        if strict_self_binding?,
          do: protect_strict_self_assignments(function.body.body, self_binding_name),
          else: protect_self_assignments(function.body.body, self_binding_name)

      with {:ok, scope} <- Declarations.declare_program_locals(body, scope),
           {:ok, instructions, constants} <- compile_param_patterns(pattern_params, scope, [], []),
           {:ok, instructions, constants} <-
             compile_rest_param(rest_param, instructions, constants),
           {:ok, instructions, constants} <-
             compile_self_binding_prologue(self_binding_name, scope, instructions, constants),
           {:ok, instructions, constants} <-
             compile_arguments_prologue(uses_arguments_object?, scope, instructions, constants),
           {:ok, instructions, constants} <-
             compile_param_defaults(defaults, scope, instructions, constants, globals),
           {:ok, instructions, constants} <-
             compile_function_body(body, scope, instructions, constants, globals) do
        instructions =
          instructions
          |> ensure_function_return()
          |> ensure_derived_constructor_return()

        var_refs = Process.get(:compiler_var_refs, %{})
        Process.put(:compiler_var_refs, prev_var_refs)
        restore_current_self_bindings(prev_self_bindings)
        restore_strict_self_bindings(prev_strict_self_bindings)

        {local_defs, var_ref_count} =
          build_local_defs(params ++ scope.local_names, var_refs)

        priv_closure_vars =
          if class_priv do
            {_refs, locs} = class_priv

            priv_refs
            |> Enum.sort_by(&elem(&1, 1))
            |> Enum.map(fn {vn, _idx} ->
              ploc = Enum.at(locs, Map.get(priv_refs, vn, 0))

              %QuickBEAM.VM.ClosureVar{
                name: vn,
                var_idx: ploc,
                closure_type: 0,
                is_const: true,
                is_lexical: true,
                var_kind: 0
              }
            end)
          else
            []
          end

        {:ok,
         FunctionBuilder.build(
           name: name,
           args: params,
           locals: scope.local_names,
           local_defs: local_defs,
           closure_vars: priv_closure_vars,
           var_ref_count: var_ref_count,
           constants: Enum.reverse(constants),
           instructions: instructions,
           defined_arg_count: defined_arg_count(params, defaults, rest_param),
           has_prototype: true,
           has_simple_parameter_list: defaults == [] and rest_param == nil,
           new_target_allowed: true,
           func_kind: function_kind(function),
           source: ""
         )}
      else
        error ->
          Process.put(:compiler_var_refs, prev_var_refs)
          restore_current_self_bindings(prev_self_bindings)
          restore_strict_self_bindings(prev_strict_self_bindings)
          error
      end
    after
      restore_process_value(:compiler_var_refs, prev_var_refs)
      restore_current_self_bindings(prev_self_bindings)
      restore_strict_self_bindings(prev_strict_self_bindings)
      restore_process_value(:compiler_block_scopes, previous_block_scopes)
      restore_process_value(:compiler_block_scope_declaration_id, previous_block_scope_id)
    end
  end

  defp build_local_defs(all_names, var_refs) when map_size(var_refs) == 0,
    do: {Enum.map(all_names, &FunctionBuilder.var_def/1), 0}

  defp build_local_defs(all_names, var_refs) do
    {defs, _idx} =
      Enum.map_reduce(all_names, 0, fn name, next_ref_idx ->
        if Map.has_key?(var_refs, name) do
          {%{
             FunctionBuilder.var_def(name)
             | is_captured: true,
               is_lexical: true,
               var_ref_idx: next_ref_idx
           }, next_ref_idx + 1}
        else
          {FunctionBuilder.var_def(name), next_ref_idx}
        end
      end)

    {defs, Enum.count(var_refs)}
  end

  defp function_kind(%{async: true, generator: true}), do: 3
  defp function_kind(%{async: true}), do: 2
  defp function_kind(%{generator: true}), do: 1
  defp function_kind(_), do: 0

  defp compile_function_stub(function, name) do
    {params, defaults, rest_param, _pattern_params} = normalize_params(function.params || [])

    {:ok,
     FunctionBuilder.build(
       name: name,
       args: params,
       locals: [],
       constants: [],
       instructions: [:return_undef],
       defined_arg_count: defined_arg_count(params, defaults, rest_param),
       has_prototype: true,
       has_simple_parameter_list: true,
       new_target_allowed: true,
       func_kind: function_kind(function),
       source: ""
     )}
  end

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp restore_current_self_bindings(nil), do: Process.delete(:compiler_current_self_bindings)

  defp restore_current_self_bindings(bindings),
    do: Process.put(:compiler_current_self_bindings, bindings)

  defp restore_strict_self_bindings(nil), do: Process.delete(:compiler_strict_self_bindings)

  defp restore_strict_self_bindings(bindings),
    do: Process.put(:compiler_strict_self_bindings, bindings)

  defp strict_body?([
         %AST.ExpressionStatement{expression: %AST.Literal{value: "use strict"}} | _
       ]),
       do: true

  defp strict_body?(_body), do: false

  defp protect_strict_self_assignments(body, nil), do: body

  defp protect_strict_self_assignments(value, self_name) when is_list(value),
    do: Enum.map(value, &protect_strict_self_assignments(&1, self_name))

  defp protect_strict_self_assignments(
         %AST.ExpressionStatement{
           expression: %AST.AssignmentExpression{
             operator: "=",
             left: %AST.Identifier{name: name}
           }
         },
         name
       ) do
    %AST.ThrowStatement{
      type: :throw_statement,
      argument: %AST.NewExpression{
        type: :new_expression,
        callee: %AST.Identifier{type: :identifier, name: "TypeError"},
        arguments: []
      }
    }
  end

  defp protect_strict_self_assignments(%AST.ArrowFunctionExpression{} = node, self_name),
    do: %{node | body: protect_strict_self_assignments(node.body, self_name)}

  defp protect_strict_self_assignments(%AST.FunctionExpression{} = node, self_name) do
    if function_self_binding_name(node) == self_name do
      node
    else
      %{node | body: protect_strict_self_assignments(node.body, self_name)}
    end
  end

  defp protect_strict_self_assignments(%{__struct__: _} = node, self_name) do
    updates =
      node
      |> Map.from_struct()
      |> Enum.map(fn {key, value} -> {key, protect_strict_self_assignments(value, self_name)} end)
      |> Map.new()

    struct(node, updates)
  end

  defp protect_strict_self_assignments(value, _self_name), do: value

  defp protect_self_assignments(body, nil), do: body

  defp protect_self_assignments(value, self_name) when is_list(value),
    do: Enum.map(value, &protect_self_assignments(&1, self_name))

  defp protect_self_assignments(
         %AST.AssignmentExpression{
           operator: "=",
           left: %AST.Identifier{name: name},
           right: right
         },
         name
       ),
       do: protect_self_assignments(right, name)

  defp protect_self_assignments(%AST.ArrowFunctionExpression{} = node, self_name),
    do: %{node | body: protect_self_assignments(node.body, self_name)}

  defp protect_self_assignments(%AST.FunctionExpression{} = node, self_name) do
    if function_self_binding_name(node) == self_name do
      node
    else
      %{node | body: protect_self_assignments(node.body, self_name)}
    end
  end

  defp protect_self_assignments(%AST.FunctionDeclaration{} = node, self_name) do
    if function_self_binding_name(node) == self_name do
      node
    else
      %{node | body: protect_self_assignments(node.body, self_name)}
    end
  end

  defp protect_self_assignments(%{__struct__: _} = node, self_name) do
    updates =
      node
      |> Map.from_struct()
      |> Enum.map(fn {key, value} -> {key, protect_self_assignments(value, self_name)} end)
      |> Map.new()

    struct(node, updates)
  end

  defp protect_self_assignments(value, _self_name), do: value

  defp function_self_binding_name(%AST.FunctionExpression{id: %AST.Identifier{name: name}}),
    do: name

  defp function_self_binding_name(_function), do: nil

  defp eval_declared_names(function),
    do:
      [function.body | function.params]
      |> eval_literal_sources()
      |> Enum.flat_map(&eval_var_names/1)
      |> Enum.uniq()

  defp eval_literal_sources(%AST.CallExpression{
         callee: %AST.Identifier{name: "eval"},
         arguments: [%AST.Literal{value: code} | _]
       })
       when is_binary(code),
       do: [code]

  defp eval_literal_sources(%AST.FunctionExpression{}), do: []
  defp eval_literal_sources(%AST.FunctionDeclaration{}), do: []
  defp eval_literal_sources(%AST.ArrowFunctionExpression{}), do: []
  defp eval_literal_sources(%AST.ClassExpression{}), do: []
  defp eval_literal_sources(%AST.ClassDeclaration{}), do: []

  defp eval_literal_sources(%{__struct__: _} = node),
    do: node |> Map.from_struct() |> Map.values() |> eval_literal_sources()

  defp eval_literal_sources(list) when is_list(list),
    do: Enum.flat_map(list, &eval_literal_sources/1)

  defp eval_literal_sources(_value), do: []

  defp eval_var_names(code) do
    case QuickBEAM.JS.Parser.parse(code) do
      {:ok, program} ->
        Enum.flat_map(program.body, fn
          %AST.VariableDeclaration{kind: :var, declarations: declarations} ->
            Enum.flat_map(declarations, &eval_pattern_names(&1.id))

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp eval_pattern_names(%AST.Identifier{name: name}), do: [name]

  defp eval_pattern_names(%AST.ObjectPattern{properties: properties}),
    do: Enum.flat_map(properties, &eval_pattern_names/1)

  defp eval_pattern_names(%AST.ArrayPattern{elements: elements}),
    do: elements |> Enum.reject(&is_nil/1) |> Enum.flat_map(&eval_pattern_names/1)

  defp eval_pattern_names(%AST.Property{value: value}), do: eval_pattern_names(value)
  defp eval_pattern_names(%AST.RestElement{argument: argument}), do: eval_pattern_names(argument)
  defp eval_pattern_names(%AST.AssignmentPattern{left: left}), do: eval_pattern_names(left)
  defp eval_pattern_names(_pattern), do: []

  defp references_arguments?(%AST.FunctionExpression{}), do: false
  defp references_arguments?(%AST.FunctionDeclaration{}), do: false

  defp references_arguments?(%AST.ArrowFunctionExpression{body: body, params: params}),
    do: references_arguments?([body | params])

  defp references_arguments?(%AST.ClassExpression{}), do: false
  defp references_arguments?(%AST.ClassDeclaration{}), do: false

  defp references_arguments?(%AST.BlockStatement{body: body}), do: references_arguments?(body)

  defp references_arguments?(statements) when is_list(statements) do
    Enum.any?(statements, &references_arguments?/1)
  end

  defp references_arguments?(%AST.Identifier{name: "arguments"}), do: true

  defp references_arguments?(%{__struct__: _} = node) do
    node
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&references_arguments?/1)
  end

  defp references_arguments?(_), do: false

  defp compile_self_binding_prologue(nil, _scope, instructions, constants),
    do: {:ok, instructions, constants}

  defp compile_self_binding_prologue(name, scope, instructions, constants) do
    case Scope.resolve(scope, name) do
      {:loc, loc} -> {:ok, instructions ++ [{:special_object, 2}, {:put_loc, loc}], constants}
      _ -> {:ok, instructions, constants}
    end
  end

  defp compile_arguments_prologue(false, _scope, instructions, constants),
    do: {:ok, instructions, constants}

  defp compile_arguments_prologue(true, scope, instructions, constants) do
    case Scope.resolve(scope, "<arguments>") do
      {:loc, loc} ->
        {:ok, instructions ++ [{:special_object, 1}, {:put_loc, loc}], constants}

      _ ->
        {:ok, instructions, constants}
    end
  end

  defp finish_program([]), do: [:undefined, {:set_loc, 0}, :return]
  defp finish_program(instructions), do: instructions ++ [:return]

  defp ensure_derived_constructor_return(instructions) do
    if Process.get(:compiler_derived_ctor, false) and List.last(instructions) == :return_undef do
      Enum.drop(instructions, -1) ++ [:push_this, :return]
    else
      instructions
    end
  end

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

      %AST.AssignmentPattern{left: %AST.Identifier{name: name}, right: default_expr},
      {names, defaults, rest, patterns} ->
        {names ++ [name], defaults ++ [{length(names), default_expr}], rest, patterns}

      %AST.AssignmentPattern{left: pattern, right: default_expr},
      {names, defaults, rest, patterns} ->
        name = synthetic_param_name(length(names))

        {names ++ [name], defaults ++ [{length(names), default_expr}], rest,
         patterns ++ [{length(names), name, pattern}]}

      _param, {names, defaults, rest, patterns} ->
        name = synthetic_param_name(length(names))
        {names ++ [name], defaults, rest, patterns}
    end)
  end

  defp synthetic_param_name(index), do: "<param:#{index}>"

  defp defined_arg_count(params, defaults, rest_param) do
    default_indexes =
      Enum.map(defaults, fn
        {name, _default} when is_binary(name) ->
          Enum.find_index(params, &(&1 == name)) || length(params)

        {index, _default} when is_integer(index) ->
          index
      end)

    rest_indexes =
      case rest_param do
        {start, _index} -> [start]
        nil -> []
      end

    case default_indexes ++ rest_indexes do
      [] -> length(params)
      indexes -> Enum.min(indexes)
    end
  end

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
                  QuickBEAM.JS.Compiler.Slots.read(slot),
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
                  QuickBEAM.JS.Compiler.Slots.read(slot),
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
    {:ok, instructions ++ [{:rest, start}, QuickBEAM.JS.Compiler.Slots.put({:arg, index})],
     constants}
  end

  defp compile_param_defaults([], _scope, instructions, constants, _globals),
    do: {:ok, instructions, constants}

  defp compile_param_defaults([{name, default} | rest], scope, instructions, constants, globals) do
    end_label = unique_label(:default_param_end)

    slot =
      case name do
        index when is_integer(index) -> {:arg, index}
        name when is_binary(name) -> Scope.resolve(scope, name)
      end

    with {:ok, instructions, constants} <-
           compile_expression(
             default,
             scope,
             instructions ++
               [
                 QuickBEAM.JS.Compiler.Slots.read(slot),
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
        instructions ++ [QuickBEAM.JS.Compiler.Slots.put(slot), {:label, end_label}],
        constants,
        globals
      )
    end
  end
end
