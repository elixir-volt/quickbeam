defmodule QuickBEAM.JS.BytecodeCompiler.Statements do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.{Captures, Emitter, Slots}
  alias QuickBEAM.JS.Parser.AST

  def compile_all(statements, %Emitter{} = emitter) do
    with {:ok, instructions, constants} <-
           compile_all(
             statements,
             emitter.scope,
             emitter.instructions,
             emitter.constants,
             emitter.callbacks
           ) do
      Emitter.result(%{emitter | instructions: instructions, constants: constants})
    end
  end

  def compile_all([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  def compile_all([statement], scope, instructions, constants, callbacks) do
    compile(statement, scope, instructions, constants, [tail?: true], callbacks)
  end

  def compile_all([statement | rest], scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           compile(statement, scope, instructions, constants, [tail?: false], callbacks) do
      compile_all(rest, scope, instructions, constants, callbacks)
    end
  end

  def compile_non_tail(statements, %Emitter{} = emitter) do
    with {:ok, instructions, constants} <-
           compile_non_tail(
             statements,
             emitter.scope,
             emitter.instructions,
             emitter.constants,
             [],
             emitter.callbacks
           ) do
      Emitter.result(%{emitter | instructions: instructions, constants: constants})
    end
  end

  def compile_non_tail([], _scope, instructions, constants, _opts, _callbacks),
    do: {:ok, instructions, constants}

  def compile_non_tail([statement | rest], scope, instructions, constants, opts, callbacks) do
    opts = Keyword.put(opts, :tail?, false)

    with {:ok, instructions, constants} <-
           compile(statement, scope, instructions, constants, opts, callbacks) do
      compile_non_tail(rest, scope, instructions, constants, opts, callbacks)
    end
  end

  def compile(
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
        opts,
        callbacks
      ) do
    with slot when slot != :error <- callbacks.resolve.(scope, name),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      if Keyword.fetch!(opts, :tail?) do
        {:ok, instructions ++ [Slots.write(slot), {:set_loc, 0}], constants}
      else
        {:ok, instructions ++ [Slots.put(slot)], constants}
      end
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ExpressionStatement{expression: expression},
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(expression, scope, instructions, constants) do
      if Keyword.fetch!(opts, :tail?) do
        {:ok, instructions ++ [{:set_loc, 0}], constants}
      else
        {:ok, instructions ++ [:drop], constants}
      end
    end
  end

  def compile(
        %AST.VariableDeclaration{kind: kind, declarations: declarations},
        scope,
        instructions,
        constants,
        opts,
        callbacks
      )
      when kind in [:let, :const] do
    if Keyword.get(opts, :block_scope?, false) do
      compile_block_lexical_declarations(declarations, scope, instructions, constants, callbacks)
    else
      compile_variable_declarations(declarations, scope, instructions, constants, callbacks)
    end
  end

  def compile(
        %AST.VariableDeclaration{declarations: declarations},
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    compile_variable_declarations(declarations, scope, instructions, constants, callbacks)
  end

  def compile(
        %AST.FunctionDeclaration{id: %AST.Identifier{name: name}} = declaration,
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    captures = Captures.captured_names(declaration, scope)
    declaration = Captures.prepend_params(declaration, captures)

    with {:ok, function} <- callbacks.compile_function.(declaration, name),
         {:ok, instructions, constants} <-
           Captures.bind(
             captures,
             scope,
             instructions ++ [{:closure, length(constants)}],
             [function | constants]
           ) do
      case callbacks.resolve.(scope, name) do
        {:loc, loc} ->
          {:ok, instructions ++ [:dup, {:put_loc, loc}, {:put_var, name}], constants}

        :error ->
          {:error, {:unsupported, {:unresolved_identifier, name}}}
      end
    end
  end

  def compile(
        %AST.ClassDeclaration{
          id: %AST.Identifier{name: name},
          super_class: super_class,
          body: body
        },
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    {instance_body, static_body} = Enum.split_with(body, &(!static_member?(&1)))

    excluded = MapSet.new([name, super_class_name(super_class)])

    with {:loc, loc} <- callbacks.resolve.(scope, name),
         {:ok, factory} <- class_factory(name, super_class, instance_body) do
      captures =
        factory
        |> Captures.captured_names(scope)
        |> Enum.reject(&MapSet.member?(excluded, &1))

      factory = Captures.prepend_params(factory, captures)

      with {:ok, function} <- callbacks.compile_function.(factory, name) do
        instructions = instructions ++ [{:closure, length(constants)}]
        constants = [function | constants]

        {:ok, instructions, constants} =
          if captures == [] do
            {:ok, instructions, constants}
          else
            Captures.bind(captures, scope, instructions, constants)
          end

        base_instructions =
          instructions ++ [:dup, {:put_loc, loc}, {:put_var, name}]

        compile_static_members(static_body, name, scope, base_instructions, constants, callbacks)
      end
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ReturnStatement{} = statement,
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    compile_return(statement, scope, instructions, constants, opts, callbacks)
  end

  def compile(
        %AST.IfStatement{test: test, consequent: consequent, alternate: alternate},
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    else_label = callbacks.unique_label.(:else)
    end_label = callbacks.unique_label.(:endif)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(test, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile(
             consequent,
             scope,
             instructions ++ [{:jump_if_false, else_label}],
             constants,
             opts,
             callbacks
           ),
         {:ok, instructions, constants} <-
           compile_if_alternate(
             alternate,
             scope,
             instructions ++ [{:jump, end_label}, {:label, else_label}],
             constants,
             opts,
             callbacks
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  def compile(
        %AST.WhileStatement{test: test, body: body},
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    start_label = callbacks.unique_label.(:while_start)
    end_label = callbacks.unique_label.(:while_end)

    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             test,
             scope,
             instructions ++ [{:label, start_label}],
             constants
           ),
         {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions ++ [{:jump_if_false, end_label}],
             constants,
             [tail?: false, break_label: end_label, continue_label: start_label],
             callbacks
           ) do
      {:ok, instructions ++ [{:jump, start_label}, {:label, end_label}], constants}
    end
  end

  def compile(
        %AST.DoWhileStatement{body: body, test: test},
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    start_label = callbacks.unique_label.(:do_start)
    test_label = callbacks.unique_label.(:do_test)
    end_label = callbacks.unique_label.(:do_end)

    with {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions ++ [{:label, start_label}],
             constants,
             [tail?: false, break_label: end_label, continue_label: test_label],
             callbacks
           ),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             test,
             scope,
             instructions ++ [{:label, test_label}],
             constants
           ) do
      {:ok, instructions ++ [{:jump_if_true, start_label}, {:label, end_label}], constants}
    end
  end

  def compile(
        %AST.SwitchStatement{discriminant: discriminant, cases: cases},
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    end_label = callbacks.unique_label.(:switch_end)
    labels = Enum.map(cases, fn _case -> callbacks.unique_label.(:switch_case) end)

    with :ok <- validate_simple_switch(cases),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(discriminant, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_switch_tests(
             cases,
             labels,
             scope,
             instructions,
             constants,
             end_label,
             callbacks
           ),
         {:ok, instructions, constants} <-
           compile_switch_cases(
             cases,
             labels,
             scope,
             instructions,
             constants,
             end_label,
             callbacks
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    end
  end

  def compile(
        %AST.TryStatement{
          block: %AST.BlockStatement{body: body},
          handler: nil,
          finalizer: %AST.BlockStatement{body: finalizer}
        },
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    finally_label = callbacks.unique_label.(:finally)
    catch_label = callbacks.unique_label.(:catch_finally)
    done_label = callbacks.unique_label.(:try_finally_done)

    with {:ok, instructions, constants} <-
           compile_non_tail(
             body,
             scope,
             instructions ++ [{:catch, catch_label}],
             constants,
             [tail?: false, finally_label: finally_label],
             callbacks
           ),
         {:ok, finally_instructions, constants} <-
           compile_non_tail(
             finalizer,
             scope,
             [],
             constants,
             [tail?: false],
             callbacks
           ) do
      {:ok,
       instructions ++
         [
           :drop,
           :undefined,
           {:gosub, finally_label},
           :drop,
           {:jump, done_label},
           {:label, catch_label},
           {:gosub, finally_label},
           :throw,
           {:label, finally_label}
         ] ++
         finally_instructions ++
         [:ret, {:label, done_label}], constants}
    end
  end

  def compile(
        %AST.TryStatement{
          block: %AST.BlockStatement{body: [%AST.ThrowStatement{argument: argument}]},
          handler: %AST.CatchClause{
            param: %AST.Identifier{name: name},
            body: handler_body
          },
          finalizer: nil
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    with {:loc, loc} <- callbacks.resolve.(scope, name),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      compile(
        handler_body,
        scope,
        instructions ++ [{:put_loc, loc}],
        constants,
        opts,
        callbacks
      )
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ForInStatement{
          left: %AST.VariableDeclaration{
            declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: name}}]
          },
          right: %AST.ObjectExpression{properties: properties},
          body: body
        },
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    end_label = callbacks.unique_label.(:for_in_end)

    with {:loc, value_loc} <- callbacks.resolve.(scope, name),
         {:ok, keys} <- object_literal_keys(properties),
         {:ok, instructions, constants} <-
           compile_static_for_in_keys(
             keys,
             body,
             value_loc,
             scope,
             instructions,
             constants,
             end_label,
             callbacks
           ) do
      {:ok, instructions ++ [{:label, end_label}], constants}
    else
      :error -> {:error, {:unsupported, :for_in_binding}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ForInStatement{
          left: %AST.VariableDeclaration{
            declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: name}}]
          },
          right: right,
          body: body
        },
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    with {:loc, value_loc} <- callbacks.resolve.(scope, name),
         {:loc, keys_loc} <- callbacks.resolve.(scope, "<for_in_keys>"),
         {:loc, index_loc} <- callbacks.resolve.(scope, "<for_in_index>"),
         {:ok, instructions, constants} <-
           compile_object_keys(right, scope, instructions, constants, callbacks) do
      compile_indexed_iteration(
        body,
        value_loc,
        keys_loc,
        index_loc,
        scope,
        instructions,
        constants,
        callbacks,
        :for_in
      )
    else
      :error -> {:error, {:unsupported, :for_in_binding}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ForOfStatement{
          left: %AST.VariableDeclaration{
            declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: name}}]
          },
          right: right,
          body: body,
          await: false
        },
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    with {:loc, value_loc} <- callbacks.resolve.(scope, name),
         {:loc, array_loc} <- callbacks.resolve.(scope, "<for_of_array>"),
         {:loc, index_loc} <- callbacks.resolve.(scope, "<for_of_index>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_indexed_iteration(
        body,
        value_loc,
        array_loc,
        index_loc,
        scope,
        instructions,
        constants,
        callbacks,
        :for_of
      )
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ForOfStatement{
          left: %AST.VariableDeclaration{
            declarations: [
              %AST.VariableDeclarator{id: %AST.ArrayPattern{elements: elements}}
            ]
          },
          right: right,
          body: body,
          await: false
        },
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    with {:loc, value_loc} <- callbacks.resolve.(scope, "<for_of_value>"),
         {:loc, array_loc} <- callbacks.resolve.(scope, "<for_of_array>"),
         {:loc, index_loc} <- callbacks.resolve.(scope, "<for_of_index>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_indexed_iteration_with_destructuring(
        body,
        elements,
        value_loc,
        array_loc,
        index_loc,
        scope,
        instructions,
        constants,
        callbacks
      )
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
      {:error, _} = error -> error
    end
  end

  def compile(%AST.ForStatement{} = statement, scope, instructions, constants, _opts, callbacks) do
    test_label = callbacks.unique_label.(:for_test)
    update_label = callbacks.unique_label.(:for_update)
    end_label = callbacks.unique_label.(:for_end)

    with {:ok, instructions, constants} <-
           compile_for_init(statement.init, scope, instructions, constants, callbacks),
         {:ok, instructions, constants} <-
           compile_for_test(
             statement.test,
             scope,
             instructions ++ [{:label, test_label}],
             constants,
             end_label,
             callbacks
           ),
         {:ok, instructions, constants} <-
           compile(
             statement.body,
             scope,
             instructions,
             constants,
             [tail?: false, break_label: end_label, continue_label: update_label],
             callbacks
           ),
         {:ok, instructions, constants} <-
           compile_for_update(
             statement.update,
             scope,
             instructions ++ [{:label, update_label}],
             constants,
             callbacks
           ) do
      {:ok, instructions ++ [{:jump, test_label}, {:label, end_label}], constants}
    end
  end

  def compile(%AST.BreakStatement{}, _scope, instructions, constants, opts, _callbacks) do
    case Keyword.fetch(opts, :break_label) do
      {:ok, label} -> {:ok, instructions ++ [{:jump, label}], constants}
      :error -> {:error, {:unsupported, :break_outside_loop}}
    end
  end

  def compile(%AST.ContinueStatement{}, _scope, instructions, constants, opts, _callbacks) do
    case Keyword.fetch(opts, :continue_label) do
      {:ok, label} -> {:ok, instructions ++ [{:jump, label}], constants}
      :error -> {:error, {:unsupported, :continue_outside_loop}}
    end
  end

  def compile(%AST.BlockStatement{body: body}, scope, instructions, constants, opts, callbacks) do
    block_opts = Keyword.put(opts, :block_scope?, true)

    if Keyword.fetch!(opts, :tail?) do
      compile_all(body, scope, instructions, constants, callbacks)
    else
      compile_non_tail(body, scope, instructions, constants, block_opts, callbacks)
    end
  end

  def compile(%AST.EmptyStatement{}, _scope, instructions, constants, _opts, _callbacks),
    do: {:ok, instructions, constants}

  def compile(statement, _scope, _instructions, _constants, _opts, _callbacks),
    do: {:error, {:unsupported, statement.type}}

  defp compile_if_alternate(nil, _scope, instructions, constants, [tail?: true], _callbacks),
    do: {:ok, instructions ++ [:undefined, {:set_loc, 0}], constants}

  defp compile_if_alternate(nil, _scope, instructions, constants, _opts, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_if_alternate(alternate, scope, instructions, constants, opts, callbacks),
    do: compile(alternate, scope, instructions, constants, opts, callbacks)

  defp class_factory(name, super_class, body) do
    with {:ok, super_name} <- class_super_name(super_class),
         {:ok, properties} <- class_properties(body, super_name) do
      {:ok,
       %AST.FunctionExpression{
         type: :function_expression,
         id: %AST.Identifier{type: :identifier, name: name},
         params: [],
         body: %AST.BlockStatement{
           type: :block_statement,
           body: [
             %AST.ReturnStatement{
               type: :return_statement,
               argument: %AST.ObjectExpression{
                 type: :object_expression,
                 properties: properties,
                 parenthesized?: false
               }
             }
           ]
         },
         async: false,
         generator: false
       }}
    end
  end

  defp nameable_expression?(%AST.FunctionExpression{id: nil}), do: true
  defp nameable_expression?(%AST.ArrowFunctionExpression{}), do: true
  defp nameable_expression?(%AST.ClassExpression{id: nil}), do: true
  defp nameable_expression?(_), do: false

  defp static_member?(%AST.MethodDefinition{static: true}), do: true
  defp static_member?(%AST.FieldDefinition{static: true}), do: true
  defp static_member?(_), do: false

  defp compile_static_members([], _name, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_static_members(
         [member | rest],
         name,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           compile_static_member(member, name, scope, instructions, constants, callbacks) do
      compile_static_members(rest, name, scope, instructions, constants, callbacks)
    end
  end

  defp compile_static_member(
         %AST.MethodDefinition{
           kind: :method,
           static: true,
           computed: false,
           key: %AST.Identifier{name: method_name},
           value: value
         },
         class_name,
         _scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, function} <- callbacks.compile_function.(value, method_name) do
      {:ok,
       instructions ++
         [{:get_var, class_name}, {:closure, length(constants)}, {:put_field, method_name}],
       [function | constants]}
    end
  end

  defp compile_static_member(
         %AST.FieldDefinition{
           static: true,
           computed: false,
           key: %AST.Identifier{name: field_name},
           value: value
         },
         class_name,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             value,
             scope,
             instructions ++ [{:get_var, class_name}],
             constants
           ) do
      {:ok, instructions ++ [{:put_field, field_name}], constants}
    end
  end

  defp compile_static_member(
         %AST.MethodDefinition{
           kind: :method,
           static: true,
           computed: true,
           key: key,
           value: value
         },
         class_name,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             key,
             scope,
             instructions ++ [{:get_var, class_name}],
             constants
           ),
         {:ok, function} <- callbacks.compile_function.(value, nil) do
      {:ok, instructions ++ [{:closure, length(constants)}, :define_array_el, :drop],
       [function | constants]}
    end
  end

  defp compile_static_member(_member, _name, _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, :class_element}}

  def class_factory_from_expression(name, super_class, body, _scope) do
    {instance_body, _static_body} = Enum.split_with(body, &(!static_member?(&1)))
    class_factory(name, super_class, instance_body)
  end

  defp super_class_name(%AST.Identifier{name: name}), do: name
  defp super_class_name(_), do: nil

  defp class_super_name(nil), do: {:ok, nil}
  defp class_super_name(%AST.Identifier{name: name}), do: {:ok, name}
  defp class_super_name(_super_class), do: {:error, {:unsupported, :class_super}}

  defp class_properties(body, super_name) do
    Enum.reduce_while(body, {:ok, []}, fn definition, {:ok, properties} ->
      case class_property(definition, super_name) do
        {:ok, next_properties} -> {:cont, {:ok, next_properties ++ properties}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, properties} -> {:ok, Enum.reverse(properties)}
      error -> error
    end
  end

  defp class_property(
         %AST.MethodDefinition{
           kind: :method,
           static: false,
           computed: computed,
           key: key,
           value: value
         },
         super_name
       ) do
    {:ok,
     [
       %AST.Property{
         type: :property,
         key: key,
         value: rewrite_super(value, super_name),
         kind: :init,
         method: false,
         shorthand: false,
         computed: computed
       }
     ]}
  end

  defp class_property(
         %AST.MethodDefinition{
           kind: :constructor,
           value: %AST.FunctionExpression{body: %AST.BlockStatement{body: body}}
         },
         _super_name
       ) do
    constructor_properties(body)
  end

  defp class_property(%AST.MethodDefinition{}, _super_name),
    do: {:error, {:unsupported, :class_element}}

  defp class_property(%AST.FieldDefinition{}, _super_name),
    do: {:error, {:unsupported, :class_element}}

  defp rewrite_super(value, nil), do: value

  defp rewrite_super(%AST.FunctionExpression{body: body} = function, super_name),
    do: %{function | body: rewrite_super(body, super_name)}

  defp rewrite_super(%AST.BlockStatement{body: body} = block, super_name),
    do: %{block | body: Enum.map(body, &rewrite_super(&1, super_name))}

  defp rewrite_super(%AST.ReturnStatement{argument: argument} = statement, super_name),
    do: %{statement | argument: rewrite_super(argument, super_name)}

  defp rewrite_super(%AST.ExpressionStatement{expression: expression} = statement, super_name),
    do: %{statement | expression: rewrite_super(expression, super_name)}

  defp rewrite_super(%AST.BinaryExpression{left: left, right: right} = expression, super_name),
    do: %{
      expression
      | left: rewrite_super(left, super_name),
        right: rewrite_super(right, super_name)
    }

  defp rewrite_super(
         %AST.CallExpression{callee: callee, arguments: args} = expression,
         super_name
       ),
       do: %{
         expression
         | callee: rewrite_super(callee, super_name),
           arguments: Enum.map(args, &rewrite_super(&1, super_name))
       }

  defp rewrite_super(
         %AST.MemberExpression{object: %AST.Identifier{name: "super"}} = expression,
         super_name
       ) do
    %{expression | object: superclass_call(super_name)}
  end

  defp rewrite_super(
         %AST.MemberExpression{object: object, property: property} = expression,
         super_name
       ) do
    %{
      expression
      | object: rewrite_super(object, super_name),
        property: rewrite_super(property, super_name)
    }
  end

  defp rewrite_super(expression, _super_name), do: expression

  defp superclass_call(super_name) do
    %AST.CallExpression{
      type: :call_expression,
      callee: %AST.Identifier{type: :identifier, name: super_name},
      arguments: [],
      optional: false
    }
  end

  defp constructor_properties(body) do
    Enum.reduce_while(body, {:ok, []}, fn
      %AST.ExpressionStatement{
        expression: %AST.AssignmentExpression{
          operator: "=",
          left: %AST.MemberExpression{
            object: %AST.Identifier{name: "this"},
            property: %AST.Identifier{} = key,
            computed: false
          },
          right: value
        }
      },
      {:ok, properties} ->
        property = %AST.Property{
          type: :property,
          key: key,
          value: value,
          kind: :init,
          method: false,
          shorthand: false,
          computed: false
        }

        {:cont, {:ok, [property | properties]}}

      _statement, _acc ->
        {:halt, {:error, {:unsupported, :class_constructor_body}}}
    end)
    |> case do
      {:ok, properties} -> {:ok, Enum.reverse(properties)}
      error -> error
    end
  end

  defp compile_object_keys(right, scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             right,
             scope,
             instructions ++ [{:get_var, "Object"}, {:get_field2, "keys"}],
             constants
           ) do
      {:ok, instructions ++ [{:call_method, 1}], constants}
    end
  end

  defp compile_indexed_iteration(
         body,
         value_loc,
         collection_loc,
         index_loc,
         scope,
         instructions,
         constants,
         callbacks,
         label_prefix
       ) do
    start_label = callbacks.unique_label.(String.to_atom("#{label_prefix}_start"))
    update_label = callbacks.unique_label.(String.to_atom("#{label_prefix}_update"))
    end_label = callbacks.unique_label.(String.to_atom("#{label_prefix}_end"))

    with {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions ++
               indexed_iteration_prefix(
                 collection_loc,
                 index_loc,
                 value_loc,
                 start_label,
                 end_label
               ),
             constants,
             [tail?: false, break_label: end_label, continue_label: update_label],
             callbacks
           ) do
      {:ok,
       instructions ++ indexed_iteration_suffix(index_loc, start_label, update_label, end_label),
       constants}
    end
  end

  defp compile_indexed_iteration_with_destructuring(
         body,
         elements,
         value_loc,
         collection_loc,
         index_loc,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    start_label = callbacks.unique_label.(:for_of_start)
    update_label = callbacks.unique_label.(:for_of_update)
    end_label = callbacks.unique_label.(:for_of_end)

    prefix =
      indexed_iteration_prefix(collection_loc, index_loc, value_loc, start_label, end_label)

    with {:ok, instructions, constants} <-
           compile_array_pattern(
             elements,
             scope,
             instructions ++ prefix ++ [{:get_loc, value_loc}],
             constants,
             callbacks
           ),
         {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions,
             constants,
             [tail?: false, break_label: end_label, continue_label: update_label],
             callbacks
           ) do
      {:ok,
       instructions ++ indexed_iteration_suffix(index_loc, start_label, update_label, end_label),
       constants}
    end
  end

  defp indexed_iteration_prefix(collection_loc, index_loc, value_loc, start_label, end_label) do
    [
      {:put_loc, collection_loc},
      {:push_int, 0},
      {:put_loc, index_loc},
      {:label, start_label},
      {:get_loc, index_loc},
      {:get_loc, collection_loc},
      :get_length,
      :lt,
      {:jump_if_false, end_label},
      {:get_loc, collection_loc},
      {:get_loc, index_loc},
      :get_array_el,
      {:put_loc, value_loc}
    ]
  end

  defp indexed_iteration_suffix(index_loc, start_label, update_label, end_label) do
    [
      {:label, update_label},
      {:get_loc, index_loc},
      {:push_int, 1},
      :add,
      {:put_loc, index_loc},
      {:jump, start_label},
      {:label, end_label}
    ]
  end

  defp object_literal_keys(properties) do
    Enum.reduce_while(properties, {:ok, []}, fn
      %AST.Property{computed: false, key: %AST.Identifier{name: name}}, {:ok, keys} ->
        {:cont, {:ok, [name | keys]}}

      %AST.Property{computed: false, key: %AST.Literal{value: value}}, {:ok, keys}
      when is_binary(value) or is_number(value) ->
        {:cont, {:ok, [to_string(value) | keys]}}

      _property, _acc ->
        {:halt, {:error, {:unsupported, :for_in_property_key}}}
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      error -> error
    end
  end

  defp compile_static_for_in_keys(
         [],
         _body,
         _value_loc,
         _scope,
         instructions,
         constants,
         _end_label,
         _callbacks
       ),
       do: {:ok, instructions, constants}

  defp compile_static_for_in_keys(
         [key | keys],
         body,
         value_loc,
         scope,
         instructions,
         constants,
         end_label,
         callbacks
       ) do
    continue_label = callbacks.unique_label.(:for_in_continue)
    {instruction, constants} = add_constant(key, constants)

    with {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions ++ [instruction, {:put_loc, value_loc}],
             constants,
             [tail?: false, break_label: end_label, continue_label: continue_label],
             callbacks
           ) do
      compile_static_for_in_keys(
        keys,
        body,
        value_loc,
        scope,
        instructions ++ [{:label, continue_label}],
        constants,
        end_label,
        callbacks
      )
    end
  end

  defp add_constant(value, constants), do: {{:constant, length(constants)}, [value | constants]}

  defp validate_simple_switch(cases) do
    cases
    |> Enum.with_index()
    |> Enum.all?(fn {switch_case, index} ->
      simple_switch_case?(switch_case, index == length(cases) - 1)
    end)
    |> case do
      true -> :ok
      false -> {:error, {:unsupported, :switch_fallthrough}}
    end
  end

  defp simple_switch_case?(%AST.SwitchCase{test: nil}, last?), do: last?

  defp simple_switch_case?(%AST.SwitchCase{consequent: consequent}, true) do
    consequent == [] or match?([%AST.BreakStatement{} | _], Enum.reverse(consequent))
  end

  defp simple_switch_case?(%AST.SwitchCase{consequent: consequent}, false) do
    match?([%AST.BreakStatement{} | _], Enum.reverse(consequent))
  end

  defp compile_switch_tests([], [], _scope, instructions, constants, end_label, _callbacks),
    do: {:ok, instructions ++ [:drop, {:jump, end_label}], constants}

  defp compile_switch_tests(
         [%AST.SwitchCase{test: nil} | _cases],
         [label | _labels],
         _scope,
         instructions,
         constants,
         _end_label,
         _callbacks
       ),
       do: {:ok, instructions ++ [{:jump, label}], constants}

  defp compile_switch_tests(
         [%AST.SwitchCase{test: test} | cases],
         [label | labels],
         scope,
         instructions,
         constants,
         end_label,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(test, scope, instructions ++ [:dup], constants) do
      compile_switch_tests(
        cases,
        labels,
        scope,
        instructions ++ [:strict_eq, {:jump_if_true, label}],
        constants,
        end_label,
        callbacks
      )
    end
  end

  defp compile_switch_cases([], [], _scope, instructions, constants, _end_label, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_switch_cases(
         [%AST.SwitchCase{consequent: consequent} | cases],
         [label | labels],
         scope,
         instructions,
         constants,
         end_label,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           compile_non_tail(
             consequent,
             scope,
             instructions ++ [{:label, label}, :drop],
             constants,
             [tail?: false, break_label: end_label],
             callbacks
           ) do
      compile_switch_cases(cases, labels, scope, instructions, constants, end_label, callbacks)
    end
  end

  defp compile_variable_declarations(declarations, scope, instructions, constants, callbacks) do
    Enum.reduce_while(declarations, {:ok, instructions, constants}, fn declaration,
                                                                       {:ok, ins, consts} ->
      case compile_declarator(declaration, scope, ins, consts, callbacks) do
        {:ok, ins, consts} -> {:cont, {:ok, ins, consts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_block_lexical_declarations(declarations, scope, instructions, constants, callbacks) do
    Enum.reduce_while(declarations, {:ok, instructions, constants}, fn declaration,
                                                                       {:ok, ins, consts} ->
      case compile_block_lexical_declarator(declaration, scope, ins, consts, callbacks) do
        {:ok, ins, consts} -> {:cont, {:ok, ins, consts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_for_init(nil, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_for_init(
         %AST.VariableDeclaration{} = declaration,
         scope,
         instructions,
         constants,
         callbacks
       ),
       do: compile(declaration, scope, instructions, constants, [tail?: false], callbacks)

  defp compile_for_init(expression, scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(expression, scope, instructions, constants) do
      {:ok, instructions ++ [{:put_loc, 0}], constants}
    end
  end

  defp compile_for_test(nil, _scope, instructions, constants, _end_label, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_for_test(test, scope, instructions, constants, end_label, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(test, scope, instructions, constants) do
      {:ok, instructions ++ [{:jump_if_false, end_label}], constants}
    end
  end

  defp compile_for_update(nil, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_for_update(update, scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(update, scope, instructions, constants) do
      {:ok, instructions ++ [{:put_loc, 0}], constants}
    end
  end

  defp compile_block_lexical_declarator(
         %AST.VariableDeclarator{init: nil},
         _scope,
         instructions,
         constants,
         _callbacks
       ),
       do: {:ok, instructions ++ [:undefined, {:put_loc, 0}], constants}

  defp compile_block_lexical_declarator(
         %AST.VariableDeclarator{init: init},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(init, scope, instructions, constants) do
      {:ok, instructions ++ [{:put_loc, 0}], constants}
    end
  end

  defp compile_declarator(
         %AST.VariableDeclarator{id: %AST.Identifier{name: name}, init: nil},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} -> {:ok, instructions ++ [:undefined, {:put_loc, loc}], constants}
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_declarator(
         %AST.VariableDeclarator{id: %AST.Identifier{name: name}, init: init},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:loc, loc} <- callbacks.resolve.(scope, name),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(init, scope, instructions, constants) do
      instructions =
        if nameable_expression?(init),
          do: instructions ++ [{:set_name, name}],
          else: instructions

      {:ok, instructions ++ [{:put_loc, loc}], constants}
    else
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
      {:error, _} = error -> error
    end
  end

  defp compile_declarator(
         %AST.VariableDeclarator{id: %AST.ObjectPattern{properties: properties}, init: init},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(init, scope, instructions, constants) do
      compile_object_pattern(properties, scope, instructions, constants, callbacks)
    end
  end

  defp compile_declarator(
         %AST.VariableDeclarator{id: %AST.ArrayPattern{elements: elements}, init: init},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(init, scope, instructions, constants) do
      compile_array_pattern(elements, scope, instructions, constants, callbacks)
    end
  end

  defp compile_declarator(
         %AST.VariableDeclarator{id: pattern},
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, {:declaration_pattern, pattern.type}}}

  defp compile_array_pattern([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:drop], constants}

  defp compile_array_pattern([element], scope, instructions, constants, callbacks),
    do:
      compile_array_pattern_element(element, 0, scope, instructions, constants, callbacks, false)

  defp compile_array_pattern([element | rest], scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           compile_array_pattern_element(
             element,
             0,
             scope,
             instructions,
             constants,
             callbacks,
             true
           ) do
      compile_array_pattern_rest(rest, 1, scope, instructions, constants, callbacks)
    end
  end

  defp compile_array_pattern_rest([], _index, _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:drop], constants}

  defp compile_array_pattern_rest(
         [element | rest],
         index,
         scope,
         instructions,
         constants,
         callbacks
       ) do
    keep_array? = true

    with {:ok, instructions, constants} <-
           compile_array_pattern_element(
             element,
             index,
             scope,
             instructions,
             constants,
             callbacks,
             keep_array?
           ) do
      compile_array_pattern_rest(rest, index + 1, scope, instructions, constants, callbacks)
    end
  end

  defp compile_array_pattern_element(
         nil,
         _index,
         _scope,
         instructions,
         constants,
         _callbacks,
         _keep_array?
       ),
       do: {:ok, instructions, constants}

  defp compile_array_pattern_element(
         %AST.Identifier{name: name},
         index,
         scope,
         instructions,
         constants,
         callbacks,
         keep_array?
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} ->
        prefix = if keep_array?, do: [:dup], else: []

        {:ok, instructions ++ prefix ++ [{:push_int, index}, :get_array_el, {:put_loc, loc}],
         constants}

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_array_pattern_element(
         _element,
         _index,
         _scope,
         _instructions,
         _constants,
         _callbacks,
         _keep_array?
       ),
       do: {:error, {:unsupported, :array_pattern_element}}

  defp compile_object_pattern([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions ++ [:drop], constants}

  defp compile_object_pattern([property], scope, instructions, constants, callbacks),
    do:
      compile_object_pattern_property(property, scope, instructions, constants, callbacks, false)

  defp compile_object_pattern([property | rest], scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           compile_object_pattern_property(
             property,
             scope,
             instructions,
             constants,
             callbacks,
             true
           ) do
      compile_object_pattern(rest, scope, instructions, constants, callbacks)
    end
  end

  defp compile_object_pattern_property(
         %AST.Property{
           computed: false,
           key: %AST.Identifier{name: key},
           value: %AST.Identifier{name: name}
         },
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} ->
        prefix = if keep_object?, do: [:dup], else: []
        {:ok, instructions ++ prefix ++ [{:get_field, key}, {:put_loc, loc}], constants}

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_object_pattern_property(
         %AST.Property{} = property,
         _scope,
         _instructions,
         _constants,
         _callbacks,
         _keep_object?
       ),
       do: {:error, {:unsupported, {:object_pattern_property, property.type}}}

  defp compile_return(
         %AST.ReturnStatement{argument: nil},
         _scope,
         instructions,
         constants,
         opts,
         _callbacks
       ) do
    case Keyword.get(opts, :finally_label) do
      nil ->
        {:ok, instructions ++ [:undefined, :return], constants}

      label ->
        {:ok, instructions ++ [:undefined, :nip_catch, {:gosub, label}, :return], constants}
    end
  end

  defp compile_return(
         %AST.ReturnStatement{argument: argument},
         scope,
         instructions,
         constants,
         opts,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      case Keyword.get(opts, :finally_label) do
        nil -> {:ok, instructions ++ [:return], constants}
        label -> {:ok, instructions ++ [:nip_catch, {:gosub, label}, :return], constants}
      end
    end
  end
end
