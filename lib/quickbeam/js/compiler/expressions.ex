defmodule QuickBEAM.JS.Compiler.Expressions do
  @moduledoc false

  alias QuickBEAM.JS.Compiler.{Captures, Emitter, Operators, Scope, Slots, Statements}
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
      when is_integer(value) and value >= -2_147_483_648 and value <= 2_147_483_647 do
    {:ok, instructions ++ [{:push_int, value}], constants}
  end

  def compile(%AST.Literal{value: value}, _scope, instructions, constants, _callbacks)
      when is_integer(value) do
    {instruction, constants} = add_constant(value / 1, constants)
    {:ok, instructions ++ [instruction], constants}
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

  def compile(
        %AST.MemberExpression{
          object: %AST.Identifier{name: "this"},
          property: %AST.PrivateIdentifier{name: pname},
          computed: false
        },
        scope,
        instructions,
        constants,
        _callbacks
      ) do
    private_kinds = Process.get(:compiler_private_kinds) || %{}

    case Scope.resolve(scope, "##{pname}") do
      {:var_ref, idx} ->
        ops =
          case Map.get(private_kinds, "##{pname}") do
            :get ->
              [:push_this, {:get_var_ref_check, idx}, {:call_method, 0}]

            _ ->
              [:push_this, {:get_var_ref_check, idx}, :get_private_field]
          end

        {:ok, instructions ++ ops, constants}

      _ ->
        {:error, {:unsupported, :object_property_key}}
    end
  end

  def compile(
        %AST.MemberExpression{
          object: %AST.Identifier{name: "super"},
          property: %AST.Identifier{name: prop},
          computed: false
        },
        _scope,
        instructions,
        constants,
        _callbacks
      ) do
    {key_instr, constants} = add_constant(prop, constants)

    {:ok,
     instructions ++
       [
         :push_this,
         :dup,
         {:get_field, "__proto__"},
         {:get_field, "__proto__"},
         key_instr,
         :get_super_value
       ], constants}
  end

  def compile(%AST.Identifier{name: "undefined"}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:undefined], constants}

  def compile(%AST.Identifier{name: "NaN"}, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [{:get_var, "NaN"}], constants}

  def compile(%AST.Identifier{name: "arguments"}, scope, instructions, constants, callbacks) do
    case callbacks.resolve.(scope, "arguments") do
      slot when slot in [:error, {:global, "arguments"}] ->
        {:ok, instructions ++ [{:get_var, "arguments"}], constants}

      slot ->
        {:ok, instructions ++ [Slots.read(slot)], constants}
    end
  end

  def compile(
        %AST.MemberExpression{
          object: %AST.Identifier{name: "arguments"},
          property: %AST.Literal{value: index},
          computed: true
        },
        %{arguments_alias: count},
        instructions,
        constants,
        _callbacks
      )
      when is_integer(count) and is_integer(index) and index >= 0 and index < count do
    {:ok, instructions ++ [{:get_arg, index}], constants}
  end

  def compile(%AST.Identifier{name: name}, scope, instructions, constants, callbacks) do
    case callbacks.resolve.(scope, name) do
      :error -> compile_global_identifier(name, instructions, constants)
      {:global, global_name} -> {:ok, instructions ++ [{:get_var, global_name}], constants}
      slot -> {:ok, instructions ++ [Slots.read(slot)], constants}
    end
  end

  def compile(
        %AST.BinaryExpression{
          operator: "in",
          left: %AST.PrivateIdentifier{name: pname},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    case Scope.resolve(scope, "##{pname}") do
      {:var_ref, idx} ->
        with {:ok, instructions, constants} <-
               callbacks.compile_expression.(right, scope, instructions, constants) do
          {:ok, instructions ++ [{:get_var_ref_check, idx}, :private_in], constants}
        end

      _ ->
        {:error, {:unsupported, :private_in}}
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
      if optional_chain?(object) do
        emit_optional_delete(instructions, [property_instruction, :delete], constants, callbacks)
      else
        {:ok, instructions ++ [property_instruction, :delete], constants}
      end
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
           callbacks.compile_expression.(object, scope, instructions, constants) do
      if optional_chain?(object) do
        with {:ok, property_instructions, constants} <-
               callbacks.compile_expression.(property, scope, [], constants) do
          emit_optional_delete(
            instructions,
            property_instructions ++ [:delete],
            constants,
            callbacks
          )
        end
      else
        with {:ok, instructions, constants} <-
               callbacks.compile_expression.(property, scope, instructions, constants) do
          {:ok, instructions ++ [:delete], constants}
        end
      end
    end
  end

  def compile(
        %AST.UnaryExpression{operator: "delete", argument: %AST.Identifier{name: name}},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    case Process.get(:compiler_with_loc) do
      nil ->
        result = callbacks_delete_identifier_result(scope, name)
        {:ok, instructions ++ [result], constants}

      with_loc ->
        done_label = callbacks.unique_label.(:with_del_done)

        {:ok,
         instructions ++
           [
             {:get_loc, with_loc},
             {:with_delete_var, name, done_label},
             {:push_int, 1},
             {:label, done_label}
           ], constants}
    end
  end

  def compile(
        %AST.UnaryExpression{operator: "void", argument: argument},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      {:ok, instructions ++ [:drop, :undefined], constants}
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
        {:ok, instructions ++ [{:get_var_undef, name}, :typeof], constants}

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
            object: %AST.Identifier{name: "this"},
            property: %AST.PrivateIdentifier{name: pname},
            computed: false
          },
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    case Scope.resolve(scope, "##{pname}") do
      {:var_ref, idx} ->
        with {:ok, instructions, constants} <-
               callbacks.compile_expression.(
                 right,
                 scope,
                 instructions ++ [:push_this, {:get_var_ref_check, idx}],
                 constants
               ) do
          {:ok, instructions ++ [:swap, :put_private_field, :undefined], constants}
        end

      _ ->
        {:error, {:unsupported, :object_property_key}}
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: "=",
          left: %AST.MemberExpression{
            object: %AST.Identifier{name: "super"},
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
    {key_instr, constants} = add_constant(property, constants)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++
               [:push_this, :dup, {:get_field, "__proto__"}, {:get_field, "__proto__"}, key_instr],
             constants
           ) do
      {:ok, instructions ++ [:put_super_value, :undefined], constants}
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: operator,
          left: %AST.MemberExpression{
            object: %AST.Identifier{name: "super"},
            property: %AST.Identifier{name: property},
            computed: false
          },
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      )
      when operator != "=" do
    with {:ok, op} <- Operators.compound(operator) do
      {key_instr, constants} = add_constant(property, constants)

      super_prefix = [
        :push_this,
        :dup,
        {:get_field, "__proto__"},
        {:get_field, "__proto__"},
        key_instr
      ]

      with {:ok, instructions, constants} <-
             callbacks.compile_expression.(
               right,
               scope,
               instructions ++
                 super_prefix ++
                 [
                   :push_this,
                   :dup,
                   {:get_field, "__proto__"},
                   {:get_field, "__proto__"},
                   key_instr,
                   :get_super_value
                 ],
               constants
             ) do
        {:ok, instructions ++ [op, :put_super_value, :undefined], constants}
      end
    end
  end

  def compile(
        %AST.UpdateExpression{
          operator: operator,
          prefix: _prefix?,
          argument: %AST.MemberExpression{
            object: %AST.Identifier{name: "super"},
            property: %AST.Identifier{name: property},
            computed: false
          }
        },
        _scope,
        instructions,
        constants,
        _callbacks
      ) do
    {key_instr, constants} = add_constant(property, constants)

    super_prefix = [
      :push_this,
      :dup,
      {:get_field, "__proto__"},
      {:get_field, "__proto__"},
      key_instr
    ]

    update_op = if operator == "++", do: :post_inc, else: :post_dec

    {:ok,
     instructions ++
       super_prefix ++ super_prefix ++ [:get_super_value, update_op, :perm5, :put_super_value],
     constants}
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
          operator: operator,
          left: %AST.MemberExpression{object: object, property: property, computed: true},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      )
      when operator != "=" and operator not in ["||=", "&&=", "??="] do
    with {:ok, op} <- Operators.compound(operator),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [:to_propkey2, :dup2, :get_array_el],
             constants
           ) do
      {:ok, instructions ++ [op, :insert3, :put_array_el], constants}
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: operator,
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
      )
      when operator != "=" do
    compile_member_assignment(
      operator,
      object,
      property,
      right,
      scope,
      instructions,
      constants,
      callbacks
    )
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
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      cond do
        strict_self_binding?(name) ->
          {:ok,
           instructions ++
             [
               :drop,
               {:get_var, "TypeError"},
               {:get_var, "TypeError"},
               {:call_constructor, 0},
               :throw
             ], constants}

        self_binding?(scope, name) ->
          {:ok, instructions, constants}

        callbacks.resolve.(scope, name) == :error ->
          {:ok, instructions ++ [:dup, {:put_var, name}], constants}

        true ->
          {:ok, instructions ++ [:dup, Slots.put(callbacks.resolve.(scope, name))], constants}
      end
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
    with {:ok, op} <- Operators.compound(operator) do
      slot = callbacks.resolve.(scope, name)

      read_op = if slot == :error, do: {:get_var, name}, else: Slots.read(slot)
      write_op = if slot == :error, do: {:put_var, name}, else: Slots.put(slot)

      with {:ok, instructions, constants} <-
             callbacks.compile_expression.(
               right,
               scope,
               instructions ++ [read_op],
               constants
             ) do
        {:ok, instructions ++ [op, :dup, write_op], constants}
      end
    end
  end

  def compile(
        %AST.AssignmentExpression{
          operator: "=",
          left: %AST.ObjectPattern{properties: properties},
          right: right
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_destructuring_assignment(
        properties,
        scope,
        instructions ++ [:to_object],
        constants,
        callbacks
      )
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
    with {:ok, op} <- Operators.update(operator, prefix?) do
      slot = callbacks.resolve.(scope, name)

      if slot == :error do
        read_op = {:get_var, name}
        write_op = {:put_var, name}

        if prefix? do
          {:ok, instructions ++ [read_op, op, :dup, write_op, :drop], constants}
        else
          {:ok, instructions ++ [read_op, op, :dup, write_op, :drop], constants}
        end
      else
        suffix = update_suffix(slot, prefix?)
        {:ok, instructions ++ [Slots.read(slot), op | suffix], constants}
      end
    end
  end

  def compile(
        %AST.UpdateExpression{
          operator: operator,
          argument: %AST.MemberExpression{object: object, property: property, computed: true},
          prefix: prefix?
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, op} <- Operators.update(operator, prefix?),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants) do
      suffix = if prefix?, do: [op, :insert3], else: [op, :perm4]

      {:ok, instructions ++ [:to_propkey2, :dup2, :get_array_el | suffix] ++ [:put_array_el],
       constants}
    end
  end

  def compile(
        %AST.UpdateExpression{
          operator: operator,
          argument: %AST.MemberExpression{
            object: object,
            property: %AST.Identifier{name: property},
            computed: false
          },
          prefix: prefix?
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    with {:ok, op} <- Operators.update(operator, prefix?),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants) do
      suffix = if prefix?, do: [op, :insert2], else: [op, :perm3]

      {:ok, instructions ++ [{:get_field2, property} | suffix] ++ [{:put_field, property}],
       constants}
    end
  end

  def compile(%AST.ArrayExpression{elements: elements}, scope, instructions, constants, callbacks) do
    if Enum.any?(elements, &is_nil/1) do
      compile_sparse_array(
        elements,
        scope,
        instructions ++ [{:array_from, 0}],
        constants,
        callbacks
      )
    else
      with {:ok, instructions, constants} <-
             compile_array_elements(elements, scope, instructions, constants, callbacks) do
        {:ok, instructions ++ [{:array_from, length(elements)}], constants}
      end
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

  def compile(
        %AST.ArrowFunctionExpression{body: body, async: false, params: params},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    expression = %AST.FunctionExpression{
      type: :arrow_function_expression,
      id: nil,
      params: params,
      body: arrow_body(body),
      async: false,
      generator: false
    }

    compile(expression, scope, instructions, constants, callbacks)
  end

  def compile(
        %AST.ClassExpression{id: id, super_class: super_class, body: body},
        scope,
        instructions,
        constants,
        callbacks
      ) do
    name = function_name(id)

    with {:ok, factory} <-
           Statements.class_factory_from_expression(name, super_class, body, scope),
         {:ok, instructions, constants} <-
           compile(factory, scope, instructions, constants, callbacks) do
      bind_name = if is_binary(name), do: [:dup, {:put_var, name}], else: []
      {:ok, instructions ++ [{:call, 0}] ++ bind_name, constants}
    end
  end

  def compile(%AST.FunctionExpression{} = expression, scope, instructions, constants, callbacks) do
    captures = Captures.captured_names(expression, scope)

    if captures != [] and Captures.has_mutable_captures?(expression, captures) do
      compile_mutable_closure(expression, captures, instructions, constants, callbacks)
    else
      expression = Captures.prepend_params(expression, captures)
      prev_self_capture_names = Process.get(:compiler_self_capture_names)

      self_capture_names =
        captures
        |> Enum.filter(&Scope.self_binding?(scope, &1))
        |> MapSet.new()

      Process.put(:compiler_self_capture_names, self_capture_names)

      try do
        with {:ok, function} <-
               callbacks.compile_function.(expression, function_name(expression.id)) do
          instructions = instructions ++ [{:closure, length(constants)}]
          constants = [function | constants]

          if captures == [] do
            {:ok, instructions, constants}
          else
            Captures.bind(captures, scope, instructions, constants)
          end
        end
      after
        restore_self_capture_names(prev_self_capture_names)
      end
    end
  end

  def compile(
        %AST.TaggedTemplateExpression{
          tag: tag,
          quasi: %AST.TemplateLiteral{quasis: quasis, expressions: expressions}
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    cooked = Enum.map(quasis, & &1.value)
    raw = Enum.map(quasis, & &1.raw)

    template_constant =
      {:template_object, {:array, cooked}, {:template_object, {:array, raw}, :undefined}}

    with {:ok, tag_instructions, constants} <-
           compile_tagged_template_tag(tag, scope, [], constants, callbacks) do
      arg_count = 1 + length(expressions)

      {expr_instructions, constants} =
        Enum.reduce(expressions, {[], constants}, fn expr, {insts, consts} ->
          case callbacks.compile_expression.(expr, scope, [], consts) do
            {:ok, new_insts, new_consts} -> {insts ++ new_insts, new_consts}
          end
        end)

      call_op = tagged_template_call_op(tag, arg_count)

      {:ok,
       instructions ++
         tag_instructions ++
         [{:constant, length(constants)}] ++
         expr_instructions ++
         [call_op], [template_constant | constants]}
    end
  end

  def compile(
        %AST.CallExpression{
          callee: %AST.MemberExpression{
            object: %AST.Identifier{name: "this"},
            property: %AST.PrivateIdentifier{name: pname},
            computed: false
          },
          arguments: args
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    case Scope.resolve(scope, "##{pname}") do
      {:var_ref, idx} ->
        with {:ok, args} <- expand_call_args(args),
             {:ok, instructions, constants} <-
               compile_call_args(
                 args,
                 scope,
                 instructions ++ [:push_this, {:get_var_ref_check, idx}],
                 constants,
                 callbacks
               ) do
          {:ok, instructions ++ [{:call_method, length(args)}], constants}
        end

      _ ->
        {:error, {:unsupported, :object_property_key}}
    end
  end

  def compile(
        %AST.CallExpression{
          callee: %AST.MemberExpression{
            object: %AST.Identifier{name: "super"},
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
    {key_instr, constants} = add_constant(property, constants)

    with {:ok, args} <- expand_call_args(args),
         {:ok, instructions, constants} <-
           compile_call_args(
             args,
             scope,
             instructions ++
               [
                 :push_this,
                 :dup,
                 {:get_field, "__proto__"},
                 {:get_field, "__proto__"},
                 key_instr,
                 :get_super_value,
                 :push_this,
                 :swap
               ],
             constants,
             callbacks
           ) do
      {:ok, instructions ++ [{:call_method, length(args)}], constants}
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
    with {:ok, args} <- expand_call_args(args),
         {:ok, instructions, constants} <-
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
    with {:ok, args} <- expand_call_args(args),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(property, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions ++ [:get_array_el2], constants, callbacks) do
      {:ok, instructions ++ [{:call_method, length(args)}], constants}
    end
  end

  def compile(
        %AST.CallExpression{
          callee: %AST.Identifier{name: "super"},
          arguments: args
        },
        scope,
        instructions,
        constants,
        callbacks
      ) do
    case Process.get(:compiler_super_class) do
      %AST.Identifier{name: parent_name} ->
        with {:ok, args} <- expand_call_args(args) do
          if args == [] do
            {:ok, instructions ++ [:init_ctor], constants}
          else
            with {:ok, instructions, constants} <-
                   compile_call_args(
                     args,
                     scope,
                     instructions ++ [{:get_var, parent_name}, {:get_var, parent_name}],
                     constants,
                     callbacks
                   ) do
              {:ok, instructions ++ [{:call_constructor, length(args)}], constants}
            end
          end
        end

      _ ->
        compile_direct_call(
          %AST.Identifier{type: :identifier, name: "super"},
          args,
          scope,
          instructions,
          constants,
          callbacks
        )
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
    with {:ok, args} <- expand_call_args(args),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(callee, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions ++ [:dup], constants, callbacks) do
      {:ok, instructions ++ [{:call_constructor, length(args)}], constants}
    end
  end

  def compile(expression, _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, expression.type}}

  defp compile_member_assignment(
         operator,
         object,
         property,
         right,
         scope,
         instructions,
         constants,
         callbacks
       )
       when operator in ["||=", "&&=", "??="] do
    skip_label = callbacks.unique_label.(:logical_member_skip)
    end_label = callbacks.unique_label.(:logical_member_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++
               [{:get_field2, property}, :dup] ++
               logical_member_test(operator, skip_label) ++ [:drop],
             constants
           ) do
      {:ok,
       instructions ++
         [
           :insert2,
           {:put_field, property},
           {:jump, end_label},
           {:label, skip_label},
           :nip,
           {:label, end_label}
         ], constants}
    end
  end

  defp compile_member_assignment(
         operator,
         object,
         property,
         right,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, op} <- Operators.compound(operator),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [{:get_field2, property}],
             constants
           ) do
      {:ok, instructions ++ [op, :insert2, {:put_field, property}], constants}
    end
  end

  defp logical_member_test("||=", label), do: [{:jump_if_true, label}]
  defp logical_member_test("&&=", label), do: [{:jump_if_false, label}]
  defp logical_member_test("??=", label), do: [:is_undefined_or_null, {:jump_if_false, label}]

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
             {:ok, %{value: %{constants: constants}}} <-
               QuickBEAM.VM.BytecodeParser.decode(binary),
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

  defp optional_chain?(%AST.MemberExpression{optional: true}), do: true
  defp optional_chain?(%AST.MemberExpression{object: object}), do: optional_chain?(object)
  defp optional_chain?(_expression), do: false

  defp emit_optional_delete(instructions, delete_instructions, constants, callbacks) do
    delete_label = callbacks.unique_label.(:optional_delete)
    end_label = callbacks.unique_label.(:optional_delete_end)

    {:ok,
     instructions ++
       [
         :dup,
         :is_undefined_or_null,
         {:jump_if_false, delete_label},
         :drop,
         true,
         {:jump, end_label},
         {:label, delete_label}
       ] ++ delete_instructions ++ [{:label, end_label}], constants}
  end

  defp callbacks_delete_identifier_result(scope, name) do
    case Scope.resolve(scope, name) do
      :error -> true
      _slot -> false
    end
  end

  defp compile_direct_call(
         %AST.Identifier{name: "eval"} = callee,
         [%AST.Literal{value: code}],
         scope,
         instructions,
         constants,
         callbacks
       )
       when is_binary(code) do
    case {Scope.resolve(scope, "eval"), simple_eval_var_declarations(code)} do
      {:error, {:ok, declarations}} ->
        if simple_eval_var_conflicts_with_lexical?(declarations, scope) do
          {:ok,
           instructions ++
             [
               {:get_var, "SyntaxError"},
               {:get_var, "SyntaxError"},
               {:call_constructor, 0},
               :throw
             ], constants}
        else
          compile_simple_eval_var_declarations(
            declarations,
            scope,
            instructions,
            constants,
            callbacks
          )
        end

      _ ->
        compile_eval_identifier_call(
          callee,
          [%AST.Literal{value: code}],
          scope,
          instructions,
          constants,
          callbacks
        )
    end
  end

  defp compile_direct_call(
         %AST.Identifier{name: "eval"} = callee,
         args,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    compile_eval_identifier_call(callee, args, scope, instructions, constants, callbacks)
  end

  defp compile_direct_call(callee, args, scope, instructions, constants, callbacks) do
    compile_ordinary_call(callee, args, scope, instructions, constants, callbacks)
  end

  defp compile_eval_identifier_call(callee, args, scope, instructions, constants, callbacks) do
    case Scope.resolve(scope, "eval") do
      :error -> compile_direct_eval_call(callee, args, scope, instructions, constants, callbacks)
      _slot -> compile_ordinary_call(callee, args, scope, instructions, constants, callbacks)
    end
  end

  defp compile_ordinary_call(callee, args, scope, instructions, constants, callbacks) do
    with {:ok, args} <- expand_call_args(args),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(callee, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions, constants, callbacks) do
      {:ok, instructions ++ [{:call, length(args)}], constants}
    end
  end

  defp compile_direct_eval_call(callee, args, scope, instructions, constants, callbacks) do
    with {:ok, args} <- expand_call_args(args),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(callee, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions, constants, callbacks) do
      {:ok, instructions ++ [{:eval, length(args), 0}], constants}
    end
  end

  defp simple_eval_var_declarations(code) do
    with {:ok, program} <- QuickBEAM.JS.Parser.parse(code),
         true <- Enum.all?(program.body, &match?(%AST.VariableDeclaration{kind: :var}, &1)) do
      declarations =
        Enum.flat_map(program.body, fn %AST.VariableDeclaration{declarations: declarations} ->
          declarations
        end)

      if declarations == [], do: :error, else: {:ok, declarations}
    else
      _ -> :error
    end
  end

  defp simple_eval_var_conflicts_with_lexical?(declarations, scope) do
    Enum.any?(declarations, fn
      %AST.VariableDeclarator{id: %AST.Identifier{name: name}} ->
        Scope.local_kind(scope, name) in [:let, :const]

      _ ->
        true
    end)
  end

  defp compile_simple_eval_var_declarations(
         declarations,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    Enum.reduce_while(declarations, {:ok, instructions, constants}, fn declaration,
                                                                       {:ok, instructions,
                                                                        constants} ->
      case compile_simple_eval_var_declaration(
             declaration,
             scope,
             instructions,
             constants,
             callbacks
           ) do
        {:ok, instructions, constants} -> {:cont, {:ok, instructions, constants}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, instructions, constants} -> {:ok, instructions ++ [:undefined], constants}
      {:error, _} = error -> error
    end
  end

  defp compile_simple_eval_var_declaration(
         %AST.VariableDeclarator{id: %AST.Identifier{name: name}, init: init},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    slot = Scope.resolve(scope, name)

    with {:ok, instructions, constants} <-
           if(init == nil,
             do: {:ok, instructions, constants},
             else: callbacks.compile_expression.(init, scope, instructions, constants)
           ) do
      case {init, slot} do
        {nil, :error} -> {:ok, instructions ++ [:undefined, {:put_var, name}], constants}
        {nil, {:global, _}} -> {:ok, instructions, constants}
        {nil, _slot} -> {:ok, instructions, constants}
        {_init, :error} -> {:ok, instructions ++ [{:put_var, name}], constants}
        {_init, {:global, _}} -> {:ok, instructions ++ [{:put_var, name}], constants}
        {_init, slot} -> {:ok, instructions ++ [Slots.put(slot)], constants}
      end
    end
  end

  defp compile_simple_eval_var_declaration(
         _declaration,
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: :error

  defp compile_destructuring_assignment(properties, scope, instructions, constants, callbacks),
    do:
      compile_destructuring_assignment(properties, scope, instructions, constants, callbacks, [])

  defp compile_destructuring_assignment(
         [],
         _scope,
         instructions,
         constants,
         _callbacks,
         _excluded
       ),
       do: {:ok, instructions, constants}

  defp compile_destructuring_assignment(
         [%AST.Property{computed: false, key: %AST.Identifier{name: key}, value: target} | rest],
         scope,
         instructions,
         constants,
         callbacks,
         excluded
       ) do
    with {:ok, instructions, constants} <-
           compile_destructuring_target(key, target, scope, instructions, constants, callbacks) do
      compile_destructuring_assignment(
        rest,
        scope,
        instructions,
        constants,
        callbacks,
        excluded ++ [key]
      )
    end
  end

  defp compile_destructuring_assignment(
         [
           %AST.Property{computed: true, key: computed_key, value: target}
           | rest
         ],
         scope,
         instructions,
         constants,
         callbacks,
         excluded
       ) do
    with {:ok, instructions, constants} <-
           compile_computed_destructuring_target(
             computed_key,
             target,
             scope,
             instructions,
             constants,
             callbacks
           ) do
      compile_destructuring_assignment(
        rest,
        scope,
        instructions,
        constants,
        callbacks,
        excluded ++ [{:computed, computed_key}]
      )
    end
  end

  defp compile_destructuring_assignment(
         [%AST.RestElement{argument: %AST.Identifier{name: name}}],
         scope,
         instructions,
         constants,
         callbacks,
         excluded
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} ->
        with {:ok, instructions, constants} <-
               compile_object_assignment_rest_excluded_keys(
                 excluded,
                 scope,
                 instructions ++ [:dup],
                 constants,
                 callbacks
               ) do
          {:ok,
           instructions ++
             [
               {:array_from, length(excluded)},
               :object,
               :rot3r,
               {:copy_data_properties, 6},
               :drop,
               :swap,
               {:put_loc, loc},
               :drop
             ], constants}
        end

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_destructuring_assignment(
         _properties,
         _scope,
         _instructions,
         _constants,
         _callbacks,
         _excluded
       ),
       do: {:error, {:unsupported, :assignment_expression}}

  defp compile_object_assignment_rest_excluded_keys(
         [],
         _scope,
         instructions,
         constants,
         _callbacks
       ),
       do: {:ok, instructions, constants}

  defp compile_object_assignment_rest_excluded_keys(
         [key | rest],
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           compile_object_assignment_rest_excluded_key(
             key,
             scope,
             instructions,
             constants,
             callbacks
           ) do
      compile_object_assignment_rest_excluded_keys(
        rest,
        scope,
        instructions,
        constants,
        callbacks
      )
    end
  end

  defp compile_object_assignment_rest_excluded_key(
         {:computed, expression},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(expression, scope, instructions, constants) do
      {:ok, instructions ++ [:to_propkey], constants}
    end
  end

  defp compile_object_assignment_rest_excluded_key(
         key,
         _scope,
         instructions,
         constants,
         _callbacks
       ) do
    {key_instr, constants} = add_constant(key, constants)
    {:ok, instructions ++ [key_instr], constants}
  end

  defp compile_destructuring_target(
         key,
         %AST.MemberExpression{
           object: %AST.Identifier{name: "super"},
           property: %AST.Identifier{name: prop},
           computed: false
         },
         _scope,
         instructions,
         constants,
         _callbacks
       ) do
    {prop_instr, constants} = add_constant(prop, constants)

    {:ok,
     instructions ++
       [
         :dup,
         {:get_field, key},
         :push_this,
         :dup,
         {:get_field, "__proto__"},
         {:get_field, "__proto__"},
         prop_instr,
         :perm4,
         :perm4,
         :swap,
         :put_super_value
       ], constants}
  end

  defp compile_destructuring_target(
         key,
         %AST.MemberExpression{
           object: %AST.Identifier{name: obj_name},
           property: %AST.Identifier{name: prop_name},
           computed: false
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             %AST.Identifier{type: :identifier, name: obj_name},
             scope,
             instructions ++ [:dup, {:get_field, key}],
             constants
           ) do
      {:ok, instructions ++ [:swap, {:put_field, prop_name}], constants}
    end
  end

  defp compile_destructuring_target(
         key,
         %AST.MemberExpression{
           object: %AST.Identifier{name: obj_name},
           property: index_expr,
           computed: true
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    # Stack: [rhs_obj, ...]
    # dup, get_field key → [value, rhs_obj, ...]
    # Then need target[index] = value while keeping rhs_obj
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             %AST.Identifier{type: :identifier, name: obj_name},
             scope,
             instructions ++ [:dup, {:get_field, key}],
             constants
           ) do
      # Stack: [target, value, rhs_obj, ...]
      with {:ok, instructions, constants} <-
             callbacks.compile_expression.(index_expr, scope, instructions, constants) do
        # Stack: [index, target, value, rhs_obj, ...]
        # perm3 [a,b,c] → [a,c,b]: [index, value, target, rhs_obj, ...]
        # But put_array_el wants [val, idx, obj]: swap first two then...
        # Actually: we need [value, index, target, rhs_obj]
        # From [index, target, value, rhs_obj]: rot3 → [value, index, target, rhs_obj]
        # rot3 = taking third element to top: use perm3 then swap?
        # perm3 [a,b,c]->[a,c,b]: [index, value, target]
        # Then swap: [value, index, target]
        {:ok, instructions ++ [:perm3, :swap, :put_array_el], constants}
      end
    end
  end

  defp compile_destructuring_target(
         key,
         %AST.Identifier{name: var_name},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    case callbacks.resolve.(scope, var_name) do
      {:loc, loc} ->
        {:ok, instructions ++ [:dup, {:get_field, key}, {:put_loc, loc}], constants}

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, var_name}}}
    end
  end

  defp compile_destructuring_target(_key, _target, _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, :assignment_expression}}

  defp compile_computed_destructuring_target(
         computed_key,
         %AST.MemberExpression{
           object: %AST.Identifier{name: "super"},
           property: %AST.Identifier{name: prop},
           computed: false
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    {prop_instr, constants} = add_constant(prop, constants)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(computed_key, scope, instructions ++ [:dup], constants) do
      {:ok,
       instructions ++
         [
           :get_array_el,
           :push_this,
           :dup,
           {:get_field, "__proto__"},
           {:get_field, "__proto__"},
           prop_instr,
           :perm4,
           :perm4,
           :swap,
           :put_super_value
         ], constants}
    end
  end

  defp compile_computed_destructuring_target(
         computed_key,
         %AST.MemberExpression{
           object: %AST.Identifier{name: obj_name},
           property: %AST.Identifier{name: prop_name},
           computed: false
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             computed_key,
             scope,
             instructions ++ [:dup],
             constants
           ) do
      with {:ok, instructions, constants} <-
             callbacks.compile_expression.(
               %AST.Identifier{type: :identifier, name: obj_name},
               scope,
               instructions ++ [:get_array_el],
               constants
             ) do
        {:ok, instructions ++ [:swap, {:put_field, prop_name}], constants}
      end
    end
  end

  defp compile_computed_destructuring_target(
         computed_key,
         %AST.MemberExpression{
           object: %AST.Identifier{name: obj_name},
           property: index_expr,
           computed: true
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    # Stack: [rhs_obj, ...]
    # dup, push computed_key, get_array_el → [value, rhs_obj, ...]
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             computed_key,
             scope,
             instructions ++ [:dup],
             constants
           ) do
      with {:ok, instructions, constants} <-
             callbacks.compile_expression.(
               %AST.Identifier{type: :identifier, name: obj_name},
               scope,
               instructions ++ [:get_array_el],
               constants
             ),
           {:ok, instructions, constants} <-
             callbacks.compile_expression.(index_expr, scope, instructions, constants) do
        # Stack: [index, target, value, rhs_obj, ...]
        {:ok, instructions ++ [:perm3, :swap, :put_array_el], constants}
      end
    end
  end

  defp compile_computed_destructuring_target(
         _key,
         _target,
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, :assignment_expression}}

  defp strict_self_binding?(name),
    do: MapSet.member?(Process.get(:compiler_strict_self_bindings, MapSet.new()), name)

  defp self_binding?(scope, name) do
    Scope.self_binding?(scope, name) or
      MapSet.member?(Process.get(:compiler_current_self_bindings, MapSet.new()), name)
  end

  defp restore_self_capture_names(nil), do: Process.delete(:compiler_self_capture_names)
  defp restore_self_capture_names(names), do: Process.put(:compiler_self_capture_names, names)

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp compile_mutable_closure(expression, captures, instructions, constants, callbacks) do
    parent_var_refs = Process.get(:compiler_var_refs, %{})

    capture_var_refs =
      captures
      |> Enum.with_index(map_size(parent_var_refs))
      |> Map.new(fn {name, idx} -> {name, idx} end)

    Process.put(:compiler_var_refs, Map.merge(parent_var_refs, capture_var_refs))

    closure_vars =
      Enum.map(captures, fn name ->
        %QuickBEAM.VM.ClosureVar{
          name: name,
          var_idx: Map.fetch!(capture_var_refs, name),
          closure_type: 0,
          is_const: false,
          is_lexical: true,
          var_kind: 0
        }
      end)

    prev_closure_scope = Process.get(:compiler_closure_scope)
    Process.put(:compiler_closure_scope, capture_var_refs)

    try do
      case callbacks.compile_function.(expression, function_name(expression.id)) do
        {:ok, function} ->
          function = %{function | closure_vars: closure_vars}
          {:ok, instructions ++ [{:closure, length(constants)}], [function | constants]}

        {:error, _} = error ->
          error
      end
    after
      restore_process_value(:compiler_closure_scope, prev_closure_scope)
    end
  end

  defp compile_tagged_template_tag(
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
      {:ok, instructions ++ [{:get_field2, property}], constants}
    end
  end

  defp compile_tagged_template_tag(
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
      {:ok, instructions ++ [:get_array_el2], constants}
    end
  end

  defp compile_tagged_template_tag(tag, scope, instructions, constants, callbacks),
    do: callbacks.compile_expression.(tag, scope, instructions, constants)

  defp tagged_template_call_op(%AST.MemberExpression{}, arg_count),
    do: {:call_method, arg_count}

  defp tagged_template_call_op(_tag, arg_count),
    do: {:call, arg_count}

  defp nameable_value?(%AST.FunctionExpression{id: nil}), do: true
  defp nameable_value?(%AST.ArrowFunctionExpression{}), do: true
  defp nameable_value?(%AST.ClassExpression{id: nil}), do: true
  defp nameable_value?(_), do: false

  defp compile_global_identifier(name, instructions, constants) do
    {:ok, instructions ++ [{:get_var, name}], constants}
  end

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

  defp compile_sparse_array(elements, scope, instructions, constants, callbacks) do
    elements
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, instructions, constants}, fn
      {nil, _index}, {:ok, instructions, constants} ->
        {:cont, {:ok, instructions, constants}}

      {%AST.SpreadElement{}, _index}, {:ok, _instructions, _constants} ->
        {:halt, {:error, {:unsupported, :array_spread}}}

      {element, index}, {:ok, instructions, constants} ->
        case callbacks.compile_expression.(element, scope, instructions, constants) do
          {:ok, instructions, constants} ->
            {:cont, {:ok, instructions ++ [{:define_field, index}], constants}}

          {:error, _} = error ->
            {:halt, error}
        end
    end)
  end

  defp compile_array_elements([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

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
         [%AST.SpreadElement{argument: argument} | rest],
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      compile_object_properties(
        rest,
        scope,
        instructions ++ [:null, {:copy_data_properties, 6}, :drop, :drop],
        constants,
        callbacks
      )
    end
  end

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
         %AST.Property{computed: true, key: key, value: value, kind: kind},
         scope,
         instructions,
         constants,
         callbacks
       )
       when kind in [:get, :set] do
    flags = if(kind == :get, do: 1, else: 2) + 4

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(key, scope, instructions, constants),
         instructions = instructions ++ [:to_propkey],
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      {:ok, instructions ++ [{:define_method_computed, flags}], constants}
    end
  end

  defp compile_object_property(
         %AST.Property{computed: true, key: key, value: value, method: true},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(key, scope, instructions, constants),
         instructions = instructions ++ [:to_propkey],
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      {:ok, instructions ++ [{:define_method_computed, 4}], constants}
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
         instructions = instructions ++ [:to_propkey],
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      name_instr = if nameable_value?(value), do: [:set_name_computed], else: []
      {:ok, instructions ++ name_instr ++ [:define_array_el, :drop], constants}
    end
  end

  defp compile_object_property(
         %AST.Property{
           computed: false,
           shorthand: true,
           key: %AST.Identifier{name: "__proto__"},
           value: value
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    {key_instruction, constants} = add_constant("__proto__", constants)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             value,
             scope,
             instructions ++ [key_instruction],
             constants
           ) do
      {:ok, instructions ++ [:define_array_el, :drop], constants}
    end
  end

  defp compile_object_property(
         %AST.Property{computed: false, key: %AST.Identifier{name: "__proto__"}, value: value},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      {:ok, instructions ++ [:set_proto], constants}
    end
  end

  defp compile_object_property(
         %AST.Property{
           kind: kind,
           computed: false,
           key: %AST.Identifier{name: name},
           value: value
         },
         scope,
         instructions,
         constants,
         callbacks
       )
       when kind in [:get, :set] do
    flags = if(kind == :get, do: 1, else: 2) + 4

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      {:ok, instructions ++ [{:define_method, name, flags}], constants}
    end
  end

  defp compile_object_property(
         %AST.Property{
           computed: false,
           method: true,
           key: %AST.Identifier{name: name},
           value: value
         },
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(value, scope, instructions, constants) do
      {:ok, instructions ++ [{:define_method, name, 4}], constants}
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

  defp expand_call_args(args) do
    Enum.reduce_while(args, {:ok, []}, fn
      %AST.SpreadElement{argument: %AST.ArrayExpression{elements: elements}}, {:ok, acc} ->
        if Enum.any?(elements, &(is_nil(&1) or match?(%AST.SpreadElement{}, &1))) do
          {:halt, {:error, {:unsupported, :spread_element}}}
        else
          {:cont, {:ok, Enum.reverse(elements) ++ acc}}
        end

      %AST.SpreadElement{}, {:ok, _acc} ->
        {:halt, {:error, {:unsupported, :spread_element}}}

      arg, {:ok, acc} ->
        {:cont, {:ok, [arg | acc]}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

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

  defp arrow_body(%AST.BlockStatement{} = body), do: body

  defp arrow_body(expression) do
    %AST.BlockStatement{
      type: :block_statement,
      body: [%AST.ReturnStatement{type: :return_statement, argument: expression}]
    }
  end

  defp function_name(nil), do: nil
  defp function_name(%AST.Identifier{name: name}), do: name
end
