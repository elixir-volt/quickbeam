defmodule QuickBEAM.JS.BytecodeCompiler.Statements do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.{Emitter, Slots}
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
        {:ok, instructions ++ [{:put_loc, 0}], constants}
      end
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
    Enum.reduce_while(declarations, {:ok, instructions, constants}, fn declaration,
                                                                       {:ok, ins, consts} ->
      case compile_declarator(declaration, scope, ins, consts, callbacks) do
        {:ok, ins, consts} -> {:cont, {:ok, ins, consts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def compile(
        %AST.FunctionDeclaration{id: %AST.Identifier{name: name}} = declaration,
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    with {:ok, function} <- callbacks.compile_function.(declaration, name) do
      case callbacks.resolve.(scope, name) do
        {:loc, loc} ->
          {:ok, instructions ++ [{:closure, length(constants)}, {:put_loc, loc}],
           [function | constants]}

        :error ->
          {:error, {:unsupported, {:unresolved_identifier, name}}}
      end
    end
  end

  def compile(
        %AST.ReturnStatement{} = statement,
        scope,
        instructions,
        constants,
        _opts,
        callbacks
      ) do
    compile_return(statement, scope, instructions, constants, callbacks)
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
    start_label = callbacks.unique_label.(:for_of_start)
    update_label = callbacks.unique_label.(:for_of_update)
    end_label = callbacks.unique_label.(:for_of_end)

    with {:loc, value_loc} <- callbacks.resolve.(scope, name),
         {:loc, array_loc} <- callbacks.resolve.(scope, "<for_of_array>"),
         {:loc, index_loc} <- callbacks.resolve.(scope, "<for_of_index>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions ++
               [
                 {:put_loc, array_loc},
                 {:push_int, 0},
                 {:put_loc, index_loc},
                 {:label, start_label},
                 {:get_loc, index_loc},
                 {:get_loc, array_loc},
                 :get_length,
                 :lt,
                 {:jump_if_false, end_label},
                 {:get_loc, array_loc},
                 {:get_loc, index_loc},
                 :get_array_el,
                 {:put_loc, value_loc}
               ],
             constants,
             [tail?: false, break_label: end_label, continue_label: update_label],
             callbacks
           ) do
      {:ok,
       instructions ++
         [
           {:label, update_label},
           {:get_loc, index_loc},
           {:push_int, 1},
           :add,
           {:put_loc, index_loc},
           {:jump, start_label},
           {:label, end_label}
         ], constants}
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
    if Keyword.fetch!(opts, :tail?) do
      compile_all(body, scope, instructions, constants, callbacks)
    else
      compile_non_tail(body, scope, instructions, constants, opts, callbacks)
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
    if Enum.all?(cases, &simple_switch_case?/1) do
      :ok
    else
      {:error, {:unsupported, :switch_fallthrough}}
    end
  end

  defp simple_switch_case?(%AST.SwitchCase{test: nil}), do: false

  defp simple_switch_case?(%AST.SwitchCase{consequent: consequent}) do
    match?([%AST.BreakStatement{} | _], Enum.reverse(consequent))
  end

  defp compile_switch_tests([], [], _scope, instructions, constants, end_label, _callbacks),
    do: {:ok, instructions ++ [:drop, {:jump, end_label}], constants}

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
         %AST.VariableDeclarator{id: pattern},
         _scope,
         _instructions,
         _constants,
         _callbacks
       ),
       do: {:error, {:unsupported, {:declaration_pattern, pattern.type}}}

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
         _callbacks
       ),
       do: {:ok, instructions ++ [:undefined, :return], constants}

  defp compile_return(
         %AST.ReturnStatement{argument: argument},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      {:ok, instructions ++ [:return], constants}
    end
  end
end
