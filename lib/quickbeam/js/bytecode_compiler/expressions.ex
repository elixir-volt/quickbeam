defmodule QuickBEAM.JS.BytecodeCompiler.Expressions do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.{Emitter, Operators, Scope, Slots}
  alias QuickBEAM.JS.Parser.AST

  def compile(expression, %Emitter{} = emitter) do
    with {:ok, instructions, constants} <-
           compile(
             expression,
             emitter.scope,
             emitter.instructions,
             emitter.constants,
             emitter.callbacks
           ) do
      Emitter.result(%{emitter | instructions: instructions, constants: constants})
    end
  end

  def compile(
        %AST.Literal{value: %{pattern: pattern}, raw: raw},
        _scope,
        instructions,
        constants,
        _callbacks
      )
      when is_binary(pattern) and is_binary(raw) do
    with {:ok, bytecode} <- regexp_bytecode(raw, pattern) do
      {pattern_instruction, constants} = add_constant(pattern, constants)
      {bytecode_instruction, constants} = add_constant(bytecode, constants)
      {:ok, instructions ++ [pattern_instruction, bytecode_instruction, :regexp], constants}
    end
  end

  def compile(%AST.Literal{value: value}, _scope, instructions, constants, _callbacks)
      when is_integer(value) do
    {:ok, instructions ++ [{:push_int, value}], constants}
  end

  def compile(%AST.Literal{value: value}, _scope, instructions, constants, _callbacks)
      when is_float(value) or is_binary(value) do
    {instruction, constants} = add_constant(value, constants)
    {:ok, instructions ++ [instruction], constants}
  end

  def compile(%AST.Literal{value: nil}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:null], constants}

  def compile(%AST.Literal{value: true}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [true], constants}

  def compile(%AST.Literal{value: false}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [false], constants}

  def compile(%AST.Identifier{name: "this"}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:push_this], constants}

  def compile(%AST.Identifier{name: "undefined"}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:undefined], constants}

  def compile(%AST.Identifier{name: "NaN"}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [{:get_var, "NaN"}], constants}

  def compile(%AST.Identifier{name: name}, scope, instructions, constants, callbacks) do
    case callbacks.resolve.(scope, name) do
      :error -> compile_global_identifier(name, instructions, constants)
      {:global, global_name} -> {:ok, instructions ++ [{:get_var, global_name}], constants}
      slot -> {:ok, instructions ++ [Slots.read(slot)], constants}
    end
  end

  def compile(
        %AST.BinaryExpression{operator: operator, left: left, right: right},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, op} <- Operators.binary(operator),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(left, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      {:ok, instructions ++ [op], constants}
    end
  end

  def compile(
        %AST.UnaryExpression{
          operator: "delete",
          argument: %AST.MemberExpression{
            object: object,
            property: %AST.Identifier{name: property},
            computed: false
          }
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    {property_instruction, constants} = add_constant(property, constants)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants) do
      {:ok, instructions ++ [property_instruction, :delete], constants}
    end
  end

  def compile(
        %AST.UnaryExpression{
          operator: "delete",
          argument: %AST.MemberExpression{object: object, property: property, computed: true}
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants) do
      {:ok, instructions ++ [:delete], constants}
    end
  end

  def compile(
        %AST.UnaryExpression{operator: "typeof", argument: %AST.Identifier{name: name}},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    case callbacks.resolve.(scope, name) do
      :error ->
        {instruction, constants} = add_constant("undefined", constants)
        {:ok, instructions ++ [instruction], constants}

      _slot ->
        compile(
          %AST.Identifier{type: :identifier, name: name},
          scope,
          instructions,
          constants,
          callbacks
        )
        |> case do
          {:ok, instructions, constants} -> {:ok, instructions ++ [:typeof], constants}
          {:error, _} = error -> error
        end
    end
  end

  def compile(
        %AST.UnaryExpression{operator: operator, argument: argument},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, op} <- Operators.unary(operator),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      {:ok, instructions ++ [op], constants}
    end
  end

  def compile(
        %AST.LogicalExpression{operator: operator, left: left, right: right},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    compile_logical_expression(operator, left, right, scope, instructions, constants, callbacks)
  end

  def compile(
        %AST.TemplateLiteral{quasis: quasis, expressions: expressions},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    compile_template_literal(quasis, expressions, scope, instructions, constants, callbacks)
  end

  def compile(
        %AST.SequenceExpression{expressions: expressions},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    compile_sequence_expressions(expressions, scope, instructions, constants, callbacks)
  end

  def compile(
        %AST.ConditionalExpression{test: test, consequent: consequent, alternate: alternate},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    else_label = callbacks.unique_label.(:cond_else)
    end_label = callbacks.unique_label.(:cond_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(test, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             consequent,
             scope,
             instructions ++ [{:jump_if_false, else_label}],
             constants
           ),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             alternate,
             scope,
             instructions ++ [{:jump, end_label}, {:label, else_label}],
             constants
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: "=",
          left: %AST.MemberExpression{
            object: object,
            property: %AST.Identifier{name: property},
            computed: false
          },
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      {:ok, instructions ++ [:insert2, {:put_field, property}], constants}
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: "=",
          left: %AST.MemberExpression{object: object, property: property, computed: true},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      {:ok, instructions ++ [:insert3, :put_array_el], constants}
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: "=",
          left: %AST.Identifier{name: name},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with slot when slot != :error <- callbacks.resolve.(scope, name),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      {:ok, instructions ++ [Slots.write(slot)], constants}
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: operator,
          left: %AST.Identifier{name: name},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      )
      when operator in ["||=", "&&=", "??="] do
    case callbacks.resolve.(scope, name) do
      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}

      slot ->
        compile_logical_assignment(
          operator,
          slot,
          right,
          scope,
          instructions,
          constants,
          callbacks
        )
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: operator,
          left: %AST.Identifier{name: name},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, op} <- Operators.compound(operator),
         slot when slot != :error <- callbacks.resolve.(scope, name),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [Slots.read(slot)],
             constants
           ) do
      {:ok, instructions ++ [op, Slots.write(slot)], constants}
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.UpdateExpression{
          operator: operator,
          argument: %AST.Identifier{name: name},
          prefix: prefix?
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, op} <- Operators.update(operator, prefix?),
         slot when slot != :error <- callbacks.resolve.(scope, name) do
      suffix = update_suffix(slot, prefix?)
      {:ok, instructions ++ [Slots.read(slot), op | suffix], constants}
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  def compile(%AST.ArrayExpression{elements: elements}, scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           compile_array_elements(elements, scope, instructions, constants, callbacks) do
      {:ok, instructions ++ [{:array_from, length(elements)}], constants}
    end
  end

  def compile(
        %AST.ObjectExpression{properties: properties},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    compile_object_properties(properties, scope, instructions ++ [:object], constants, callbacks)
  end

  def compile(
        %AST.MemberExpression{object: object, property: property, computed: true},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants) do
      {:ok, instructions ++ [:get_array_el], constants}
    end
  end

  def compile(
        %AST.MemberExpression{
          object: object,
          property: %AST.Identifier{name: property},
          computed: false,
          optional: true
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    get_label = callbacks.unique_label.(:optional_get)
    end_label = callbacks.unique_label.(:optional_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants) do
      {:ok,
       instructions ++
         [
           :dup,
           :is_undefined_or_null,
           {:jump_if_false, get_label},
           :drop,
           :undefined,
           {:jump, end_label},
           {:label, get_label},
           {:get_field, property},
           {:label, end_label}
         ], constants}
    end
  end

  def compile(
        %AST.MemberExpression{
          object: object,
          property: %AST.Identifier{name: "length"},
          computed: false
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants) do
      {:ok, instructions ++ [:get_length], constants}
    end
  end

  def compile(
        %AST.MemberExpression{
          object: object,
          property: %AST.Identifier{name: property},
          computed: false
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants) do
      {:ok, instructions ++ [{:get_field, property}], constants}
    end
  end

  def compile(%AST.FunctionExpression{} = expression, scope, instructions, constants, callbacks) do
    captures = captured_names(expression, scope)
    expression = prepend_capture_params(expression, captures)

    with {:ok, function} <- callbacks.compile_function.(expression, function_name(expression.id)) do
      instructions = instructions ++ [{:closure, length(constants)}]
      constants = [function | constants]

      if captures == [] do
        {:ok, instructions, constants}
      else
        bind_captures(captures, scope, instructions, constants)
      end
    end
  end

  def compile(
        %AST.CallExpression{
          callee: %AST.MemberExpression{
            object: object,
            property: %AST.Identifier{name: property},
            computed: false
          },
          arguments: args
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(
             args,
             scope,
             instructions ++ [{:get_field2, property}],
             constants,
             callbacks
           ) do
      {:ok, instructions ++ [{:call_method, length(args)}], constants}
    end
  end

  def compile(
        %AST.CallExpression{
          callee: %AST.MemberExpression{object: object, property: property, computed: true},
          arguments: args
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions ++ [:get_array_el2], constants, callbacks) do
      {:ok, instructions ++ [{:call_method, length(args)}], constants}
    end
  end

  def compile(
        %AST.CallExpression{callee: callee, arguments: args},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    compile_direct_call(callee, args, scope, instructions, constants, callbacks)
  end

  def compile(
        %AST.NewExpression{callee: callee, arguments: args},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(callee, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions ++ [:dup], constants, callbacks) do
      {:ok, instructions ++ [{:call_constructor, length(args)}], constants}
    end
  end

  def compile(expression, _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, expression.type}}

  defp captured_names(%AST.FunctionExpression{} = expression, %Scope{} = scope) do
    declared =
      expression.params
      |> Enum.map(&identifier_name/1)
      |> Kernel.++(function_local_names(expression.body.body))
      |> MapSet.new()

    available = Scope.names(scope)

    expression.body.body
    |> collect_identifiers([])
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> Enum.filter(&(&1 in available))
    |> Enum.uniq()
  end

  defp captured_names(_expression, _scope), do: []

  defp prepend_capture_params(expression, []), do: expression

  defp prepend_capture_params(%AST.FunctionExpression{params: params} = expression, captures) do
    capture_params = Enum.map(captures, &%AST.Identifier{type: :identifier, name: &1})
    %{expression | params: capture_params ++ params}
  end

  defp bind_captures(captures, scope, instructions, constants) do
    Enum.reduce_while(
      captures,
      {:ok, instructions ++ [{:get_field2, "bind"}, :undefined], constants},
      fn name, {:ok, ins, consts} ->
        case Scope.resolve(scope, name) do
          :error -> {:halt, {:error, {:unsupported, {:unresolved_identifier, name}}}}
          slot -> {:cont, {:ok, ins ++ [Slots.read(slot)], consts}}
        end
      end
    )
    |> case do
      {:ok, instructions, constants} ->
        {:ok, instructions ++ [{:call_method, length(captures) + 1}], constants}

      {:error, _} = error ->
        error
    end
  end

  defp function_local_names(statements), do: collect_declaration_names(statements, [])

  defp collect_declaration_names([], acc), do: acc

  defp collect_declaration_names(
         [%AST.VariableDeclaration{declarations: declarations} | rest],
         acc
       ) do
    names = Enum.flat_map(declarations, &pattern_names(&1.id))
    collect_declaration_names(rest, names ++ acc)
  end

  defp collect_declaration_names([%AST.FunctionDeclaration{id: id} | rest], acc),
    do: collect_declaration_names(rest, [identifier_name(id) | acc])

  defp collect_declaration_names([_statement | rest], acc),
    do: collect_declaration_names(rest, acc)

  defp pattern_names(%AST.Identifier{} = identifier), do: [identifier_name(identifier)]
  defp pattern_names(_pattern), do: []

  defp collect_identifiers(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_identifiers/2)

  defp collect_identifiers(%AST.Identifier{name: name}, acc), do: [name | acc]

  defp collect_identifiers(%_{} = node, acc) do
    node
    |> Map.from_struct()
    |> Map.values()
    |> collect_identifiers(acc)
  end

  defp collect_identifiers(_value, acc), do: acc

  defp identifier_name(%AST.Identifier{name: name}), do: name

  defp compile_logical_assignment(
         operator,
         slot,
         right,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    end_label = callbacks.unique_label.(:logical_assignment_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++
               [Slots.read(slot), :dup] ++ logical_assignment_test(operator, end_label),
             constants
           ) do
      {:ok, instructions ++ [Slots.write(slot), {:label, end_label}], constants}
    end
  end

  defp logical_assignment_test("||=", end_label), do: [{:jump_if_true, end_label}, :drop]
  defp logical_assignment_test("&&=", end_label), do: [{:jump_if_false, end_label}, :drop]

  defp logical_assignment_test("??=", end_label),
    do: [:is_undefined_or_null, {:jump_if_false, end_label}, :drop]

  defp regexp_bytecode(raw, pattern) do
    with {:ok, rt} <- QuickBEAM.start(apis: false) do
      try do
        with {:ok, binary} <- QuickBEAM.compile(rt, raw),
             {:ok, %{value: %{constants: constants}}} <- QuickBEAM.VM.Bytecode.decode(binary),
             bytecode when is_binary(bytecode) <-
               Enum.find(constants, &regexp_bytecode_constant?(&1, pattern)) do
          {:ok, bytecode}
        else
          _ -> {:error, {:unsupported, :regexp_literal}}
        end
      after
        QuickBEAM.stop(rt)
      end
    end
  end

  defp regexp_bytecode_constant?(value, pattern), do: is_binary(value) and value != pattern

  defp compile_direct_call(callee, args, scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(callee, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions, constants, callbacks) do
      {:ok, instructions ++ [{:call, length(args)}], constants}
    end
  end

  defp compile_global_identifier(name, instructions, constants)
       when name in ["Object", "Math", "Array", "String", "Number", "Boolean"] do
    {:ok, instructions ++ [{:get_var, name}], constants}
  end

  defp compile_global_identifier(name, _instructions, _constants),
    do: {:error, {:unsupported, {:unresolved_identifier, name}}}

  defp compile_template_literal(
         [%AST.TemplateElement{value: value}],
         [],
         _scope,
         instructions,
         constants,
         _callbacks
       ) do
    {instruction, constants} = add_constant(value, constants)
    {:ok, instructions ++ [instruction], constants}
  end

  defp compile_template_literal(
         [%AST.TemplateElement{value: first} | quasis],
         expressions,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    {instruction, constants} = add_constant(first, constants)

    compile_template_parts(
      quasis,
      expressions,
      scope,
      instructions ++ [instruction],
      constants,
      callbacks
    )
  end

  defp compile_template_literal(
         _quasis,
         _expressions,
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, :template_literal}}

  defp compile_template_parts([], [], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_template_parts(
         [%AST.TemplateElement{value: value} | quasis],
         [expression | expressions],
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(expression, scope, instructions, constants) do
      instructions = instructions ++ [:add]

      if value == "" do
        compile_template_parts(quasis, expressions, scope, instructions, constants, callbacks)
      else
        {instruction, constants} = add_constant(value, constants)

        compile_template_parts(
          quasis,
          expressions,
          scope,
          instructions ++ [instruction, :add],
          constants,
          callbacks
        )
      end
    end
  end

  defp compile_template_parts(
         _quasis,
         _expressions,
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, :template_literal}}

  defp compile_sequence_expressions([], _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, :empty_sequence}}

  defp compile_sequence_expressions([expression], scope, instructions, constants, callbacks),
    do: callbacks.compile_expression.(expression, scope, instructions, constants)

  defp compile_sequence_expressions(
         [expression | rest],
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(expression, scope, instructions, constants) do
      compile_sequence_expressions(rest, scope, instructions ++ [:drop], constants, callbacks)
    end
  end

  defp compile_logical_expression("&&", left, right, scope, instructions, constants, callbacks) do
    end_label = callbacks.unique_label.(:logical_and_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(left, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [:dup, {:jump_if_false, end_label}, :drop],
             constants
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  defp compile_logical_expression("||", left, right, scope, instructions, constants, callbacks) do
    end_label = callbacks.unique_label.(:logical_or_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(left, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [:dup, {:jump_if_true, end_label}, :drop],
             constants
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  defp compile_logical_expression("??", left, right, scope, instructions, constants, callbacks) do
    end_label = callbacks.unique_label.(:logical_nullish_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(left, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [:dup, :is_undefined_or_null, {:jump_if_false, end_label}, :drop],
             constants
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  defp compile_logical_expression(
         operator,
         _left,
         _right,
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, {:logical_operator, operator}}}

  defp compile_array_elements([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_array_elements([nil | rest], _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, {:array_hole, length(rest)}}}

  defp compile_array_elements(
         [%AST.SpreadElement{} | _rest],
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, :array_spread}}

  defp compile_array_elements([element | rest], scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(element, scope, instructions, constants) do
      compile_array_elements(rest, scope, instructions, constants, callbacks)
    end
  end

  defp compile_object_properties([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_object_properties(
         [%AST.SpreadElement{} | _rest],
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, :object_spread}}

  defp compile_object_properties(
         [%AST.Property{} = property | rest],
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           compile_object_property(property, scope, instructions, constants, callbacks) do
      compile_object_properties(rest, scope, instructions, constants, callbacks)
    end
  end

  defp compile_object_property(
         %AST.Property{computed: true, key: key, value: value},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(key, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      {:ok, instructions ++ [:define_array_el, :drop], constants}
    end
  end

  defp compile_object_property(
         %AST.Property{} = property,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, key} <- property_key(property),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property.value, scope, instructions, constants) do
      {:ok, instructions ++ [{:define_field, key}], constants}
    end
  end

  defp property_key(%AST.Property{computed: false, key: %AST.Identifier{name: name}}),
    do: {:ok, name}

  defp property_key(%AST.Property{computed: false, key: %AST.Literal{value: value}})
       when is_binary(value),
       do: {:ok, value}

  defp property_key(%AST.Property{}), do: {:error, {:unsupported, :object_property_key}}

  defp compile_call_args([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_call_args([arg | rest], scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(arg, scope, instructions, constants) do
      compile_call_args(rest, scope, instructions, constants, callbacks)
    end
  end

  defp add_constant(value, constants), do: {{:constant, length(constants)}, [value | constants]}

  defp update_suffix(slot, true), do: [:dup, Slots.put(slot)]
  defp update_suffix(slot, false), do: [Slots.put(slot)]

  defp function_name(nil), do: nil
  defp function_name(%AST.Identifier{name: name}), do: name
end
