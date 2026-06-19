defmodule QuickBEAM.JS.Compiler.Statements do
  @moduledoc false

  alias QuickBEAM.JS.Compiler.{Captures, Emitter, Scope, Slots}
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

  defp compile_all([], _scope, instructions, constants, _opts, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_all([statement], scope, instructions, constants, opts, callbacks) do
    opts = Keyword.put(opts, :tail?, true)
    compile(statement, scope, instructions, constants, opts, callbacks)
  end

  defp compile_all([statement | rest], scope, instructions, constants, opts, callbacks) do
    compile_opts = Keyword.put(opts, :tail?, Keyword.get(opts, :preserve_completion?, false))
    rest_opts = Keyword.put(opts, :tail?, false)

    with {:ok, instructions, constants} <-
           compile(statement, scope, instructions, constants, compile_opts, callbacks) do
      instructions = maybe_drop_preserved_completion(instructions, statement, compile_opts)
      compile_all(rest, scope, instructions, constants, rest_opts, callbacks)
    end
  end

  defp maybe_drop_preserved_completion(instructions, %AST.ExpressionStatement{}, opts) do
    if Keyword.get(opts, :tail?) and Keyword.get(opts, :preserve_completion?) do
      instructions ++ [:drop]
    else
      instructions
    end
  end

  defp maybe_drop_preserved_completion(instructions, _statement, _opts), do: instructions

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
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      slot = callbacks.resolve.(scope, name)

      if slot == :error do
        if Keyword.fetch!(opts, :tail?) do
          {:ok, instructions ++ [:dup, {:put_var, name}, {:set_loc, 0}], constants}
        else
          {:ok, instructions ++ [{:put_var, name}], constants}
        end
      else
        if Keyword.fetch!(opts, :tail?) do
          {:ok, instructions ++ [:dup, Slots.put(slot), {:set_loc, 0}], constants}
        else
          {:ok, instructions ++ [Slots.put(slot)], constants}
        end
      end
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
        _opts,
        callbacks
      )
      when kind in [:let, :const] do
    compile_variable_declarations(declarations, scope, instructions, constants, callbacks)
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
    captures =
      declaration
      |> Captures.captured_names(scope)
      |> Enum.reject(&top_level_function_capture?(scope, &1))

    if captures != [] and references_arguments?(declaration.body) do
      with {:ok, function} <-
             compile_declaration_function(declaration, name, captures, scope, callbacks) do
        instructions = instructions ++ [{:closure, length(constants)}]
        constants = [function | constants]
        bind_function_declaration(scope, name, instructions, constants)
      end
    else
      declaration = Captures.prepend_params(declaration, captures)

      with {:ok, function} <- callbacks.compile_function.(declaration, name),
           {:ok, instructions, constants} <-
             Captures.bind(
               captures,
               scope,
               instructions ++ [{:closure, length(constants)}],
               [function | constants]
             ) do
        bind_function_declaration(scope, name, instructions, constants)
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
    case compile_class_define(name, super_class, body, scope, instructions, constants, callbacks) do
      {:ok, _, _} = ok ->
        ok

      {:error, _} ->
        compile_class_factory_fallback(
          name,
          super_class,
          body,
          scope,
          instructions,
          constants,
          callbacks
        )
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
        %AST.LabeledStatement{
          label: %AST.Identifier{name: label},
          body: %AST.DoWhileStatement{body: body, test: test}
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    compile_do_while(body, test, scope, instructions, constants, opts, callbacks, label)
  end

  def compile(
        %AST.DoWhileStatement{body: body, test: test},
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    compile_do_while(body, test, scope, instructions, constants, opts, callbacks, nil)
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
        %AST.TryStatement{
          block: %AST.BlockStatement{body: try_body},
          handler: %AST.CatchClause{param: param, body: handler_body},
          finalizer: nil
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    catch_label = callbacks.unique_label.(:catch)
    done_label = callbacks.unique_label.(:try_done)

    with {:ok, instructions, constants} <-
           compile_non_tail(
             try_body,
             scope,
             instructions ++ [{:catch, catch_label}],
             constants,
             opts |> non_tail_control_opts() |> Keyword.delete(:iterator_close_loc),
             callbacks
           ),
         {:ok, catch_instructions, constants} <-
           compile_catch_handler(param, handler_body, scope, constants, opts, callbacks) do
      {:ok,
       instructions ++
         [:drop, {:jump, done_label}, {:label, catch_label}] ++
         catch_instructions ++ [{:label, done_label}], constants}
    end
  end

  def compile(
        %AST.TryStatement{
          block: %AST.BlockStatement{body: try_body},
          handler: %AST.CatchClause{param: param, body: handler_body},
          finalizer: %AST.BlockStatement{body: finalizer}
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    finally_label = callbacks.unique_label.(:finally)
    catch_label = callbacks.unique_label.(:catch_finally)
    done_label = callbacks.unique_label.(:try_done)

    with {:ok, instructions, constants} <-
           compile_non_tail(
             try_body,
             scope,
             instructions ++ [{:catch, catch_label}],
             constants,
             opts
             |> non_tail_control_opts()
             |> Keyword.delete(:iterator_close_loc)
             |> Keyword.put(:finally_label, finally_label),
             callbacks
           ),
         {:ok, catch_instructions, constants} <-
           compile_catch_handler(param, handler_body, scope, constants, opts, callbacks),
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
           {:gosub, finally_label},
           :drop,
           {:jump, done_label},
           {:label, catch_label}
         ] ++
         catch_instructions ++
         [
           {:gosub, finally_label},
           :drop,
           {:jump, done_label},
           {:label, finally_label}
         ] ++
         finally_instructions ++ [:ret, {:label, done_label}], constants}
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
        opts,
        callbacks
      ) do
    instructions = maybe_reset_loop_completion(instructions, Keyword.fetch!(opts, :tail?))

    with {:loc, value_loc} <- callbacks.resolve.(scope, name),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_iterator_for_of(
        body,
        value_loc,
        scope,
        instructions,
        constants,
        callbacks,
        Keyword.fetch!(opts, :tail?),
        [],
        opts
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
        opts,
        callbacks
      ) do
    instructions = maybe_reset_loop_completion(instructions, Keyword.fetch!(opts, :tail?))

    with {:loc, value_loc} <- callbacks.resolve.(scope, "<for_of_value>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_iterator_for_of_destructuring(
        body,
        elements,
        value_loc,
        scope,
        instructions,
        constants,
        callbacks,
        Keyword.fetch!(opts, :tail?),
        opts
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
              %AST.VariableDeclarator{id: %AST.ObjectPattern{properties: properties}}
            ]
          },
          right: right,
          body: body,
          await: false
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    instructions = maybe_reset_loop_completion(instructions, Keyword.fetch!(opts, :tail?))

    with {:loc, value_loc} <- callbacks.resolve.(scope, "<for_of_value>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_iterator_for_of_object_pattern(
        body,
        properties,
        value_loc,
        scope,
        instructions,
        constants,
        callbacks,
        Keyword.fetch!(opts, :tail?),
        opts
      )
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ForOfStatement{
          left: %AST.ObjectExpression{properties: properties},
          right: right,
          body: body,
          await: false
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    instructions = maybe_reset_loop_completion(instructions, Keyword.fetch!(opts, :tail?))

    with {:loc, value_loc} <- callbacks.resolve.(scope, "<for_of_value>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      compile_iterator_for_of_object_pattern(
        body,
        properties,
        value_loc,
        scope,
        instructions,
        constants,
        callbacks,
        Keyword.fetch!(opts, :tail?),
        opts
      )
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
      {:error, _} = error -> error
    end
  end

  def compile(
        %AST.ForOfStatement{
          left: %AST.Identifier{name: name},
          right: right,
          body: body,
          await: false
        },
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    instructions = maybe_reset_loop_completion(instructions, Keyword.fetch!(opts, :tail?))

    case callbacks.resolve.(scope, name) do
      {:loc, value_loc} ->
        with {:ok, instructions, constants} <-
               callbacks.compile_expression.(right, scope, instructions, constants) do
          compile_iterator_for_of(
            body,
            value_loc,
            scope,
            instructions,
            constants,
            callbacks,
            Keyword.fetch!(opts, :tail?),
            [],
            opts
          )
        end

      {:global, ^name} ->
        with {:loc, value_loc} <- callbacks.resolve.(scope, "<for_of_value>"),
             {:ok, instructions, constants} <-
               callbacks.compile_expression.(right, scope, instructions, constants) do
          compile_iterator_for_of(
            body,
            value_loc,
            scope,
            instructions,
            constants,
            callbacks,
            Keyword.fetch!(opts, :tail?),
            [{:get_loc, value_loc}, {:put_var, name}],
            opts
          )
        end

      :error ->
        {:error, {:unsupported, :for_of_binding}}
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

  def compile(
        %AST.BreakStatement{label: label},
        _scope,
        instructions,
        constants,
        opts,
        _callbacks
      ) do
    case resolve_jump_label(opts, :break_label, :break_labels, label) do
      {:ok, label} ->
        {:ok, instructions ++ iterator_close_ops(opts) ++ [{:jump, label}], constants}

      :error ->
        {:error, {:unsupported, :break_outside_loop}}
    end
  end

  def compile(
        %AST.ContinueStatement{label: label},
        _scope,
        instructions,
        constants,
        opts,
        _callbacks
      ) do
    case resolve_jump_label(opts, :continue_label, :continue_labels, label) do
      {:ok, label} ->
        close_ops =
          if label == Keyword.get(opts, :continue_label), do: [], else: iterator_close_ops(opts)

        {:ok, instructions ++ close_ops ++ [{:jump, label}], constants}

      :error ->
        {:error, {:unsupported, :continue_outside_loop}}
    end
  end

  def compile(%AST.BlockStatement{body: body}, scope, instructions, constants, opts, callbacks) do
    block_scope = enter_block_scope(scope)
    block_opts = Keyword.put(opts, :block_scope?, true)

    if Keyword.fetch!(opts, :tail?) do
      compile_all(body, block_scope, instructions, constants, block_opts, callbacks)
    else
      compile_non_tail(body, block_scope, instructions, constants, block_opts, callbacks)
    end
  end

  def compile(
        %AST.WithStatement{object: object, body: body},
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    with {:loc, with_loc} <- callbacks.resolve.(scope, "<with_obj>"),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(object, scope, instructions, constants) do
      instructions = instructions ++ [{:put_loc, with_loc}]
      prev_with = Process.get(:compiler_with_loc)
      Process.put(:compiler_with_loc, with_loc)

      try do
        compile(body, scope, instructions, constants, opts, callbacks)
      after
        restore_process_value(:compiler_with_loc, prev_with)
      end
    else
      :error -> {:error, {:unsupported, :with_statement}}
      {:error, _} = error -> error
    end
  end

  def compile(%AST.EmptyStatement{}, _scope, instructions, constants, _opts, _callbacks),
    do: {:ok, instructions, constants}

  def compile(
        %AST.ThrowStatement{argument: argument},
        scope,
        instructions,
        constants,
        opts,
        callbacks
      ) do
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(argument, scope, instructions, constants) do
      {:ok, instructions ++ iterator_close_ops(opts) ++ [:throw], constants}
    end
  end

  def compile(statement, _scope, _instructions, _constants, _opts, _callbacks),
    do: {:error, {:unsupported, statement.type}}

  defp top_level_function_capture?(scope, name) do
    Map.has_key?(scope.locals, "<ret>") and
      MapSet.member?(Process.get(:compiler_top_level_function_names, MapSet.new()), name)
  end

  defp bind_function_declaration(scope, name, instructions, constants) do
    case Scope.resolve(scope, name) do
      {:loc, loc} ->
        {:ok, instructions ++ [:dup, {:put_loc, loc}, {:put_var, name}], constants}

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp references_arguments?(%AST.Identifier{name: "arguments"}), do: true
  defp references_arguments?(%AST.FunctionDeclaration{}), do: false
  defp references_arguments?(%AST.FunctionExpression{}), do: false
  defp references_arguments?(%AST.ArrowFunctionExpression{}), do: false
  defp references_arguments?(%AST.ClassDeclaration{}), do: false
  defp references_arguments?(%AST.ClassExpression{}), do: false

  defp references_arguments?(%{__struct__: _} = node) do
    node
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(&references_arguments?/1)
  end

  defp references_arguments?(list) when is_list(list),
    do: Enum.any?(list, &references_arguments?/1)

  defp references_arguments?(_), do: false

  defp compile_declaration_function(declaration, name, [], _scope, callbacks),
    do: callbacks.compile_function.(declaration, name)

  defp compile_declaration_function(declaration, name, captures, scope, callbacks) do
    parent_var_refs = Process.get(:compiler_var_refs) || %{}

    parent_capture_var_refs =
      captures
      |> Enum.with_index(map_size(parent_var_refs))
      |> Map.new(fn {capture_name, idx} -> {capture_name, idx} end)

    child_capture_var_refs =
      captures
      |> Enum.with_index()
      |> Map.new(fn {capture_name, idx} -> {capture_name, idx} end)

    Process.put(:compiler_var_refs, Map.merge(parent_var_refs, parent_capture_var_refs))

    closure_vars =
      Enum.map(captures, fn capture_name ->
        {closure_type, var_idx} = capture_source_slot(scope, capture_name)

        %QuickBEAM.VM.ClosureVar{
          name: capture_name,
          var_idx: var_idx,
          closure_type: closure_type,
          is_const: false,
          is_lexical: true,
          var_kind: 0
        }
      end)

    prev_closure_scope = Process.get(:compiler_closure_scope)
    Process.put(:compiler_closure_scope, child_capture_var_refs)

    try do
      case callbacks.compile_function.(declaration, name) do
        {:ok, function} ->
          {:ok, %{function | closure_vars: closure_vars, var_ref_count: length(closure_vars)}}

        {:error, _} = error ->
          error
      end
    after
      restore_process_value(:compiler_closure_scope, prev_closure_scope)
    end
  end

  defp capture_source_slot(scope, name) do
    case Scope.resolve(scope, name) do
      {:arg, idx} -> {1, idx}
      {:loc, idx} -> {0, idx}
      {:var_ref, idx} -> {2, idx}
      _ -> {0, Map.get(scope.locals, name, 0)}
    end
  end

  defp compile_if_alternate(nil, _scope, instructions, constants, [tail?: true], _callbacks),
    do: {:ok, instructions ++ [:undefined, {:set_loc, 0}], constants}

  defp compile_if_alternate(nil, _scope, instructions, constants, _opts, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_if_alternate(alternate, scope, instructions, constants, opts, callbacks),
    do: compile(alternate, scope, instructions, constants, opts, callbacks)

  defp class_factory(_name, super_class, body) do
    with {:ok, super_name} <- class_super_name(super_class),
         {:ok, properties} <- class_properties(body, super_name) do
      {:ok,
       %AST.FunctionExpression{
         type: :function_expression,
         id: nil,
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

  defp compile_stub_class(name, scope, instructions, constants, callbacks) do
    stub = %AST.FunctionExpression{
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
              properties: [],
              parenthesized?: false
            }
          }
        ]
      },
      async: false,
      generator: false
    }

    with {:loc, loc} <- callbacks.resolve.(scope, name),
         {:ok, function} <- callbacks.compile_function.(stub, name) do
      {:ok,
       instructions ++ [{:closure, length(constants)}, :dup, {:put_loc, loc}, {:put_var, name}],
       [function | constants]}
    end
  end

  defp compile_class_factory_fallback(
         name,
         super_class,
         body,
         scope,
         instructions,
         constants,
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
      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}

      {:error, {:unsupported, :class_constructor_body}} ->
        compile_stub_class(name, scope, instructions, constants, callbacks)

      {:error, _} = error ->
        error
    end
  end

  defp compile_class_define(name, super_class, body, scope, instructions, constants, callbacks) do
    private_names =
      body
      |> Enum.flat_map(fn
        %{key: %AST.PrivateIdentifier{name: pn}} -> [pn]
        _ -> []
      end)
      |> Enum.uniq()

    field_names =
      body
      |> Enum.filter(&match?(%AST.FieldDefinition{key: %AST.PrivateIdentifier{}}, &1))
      |> Enum.map(& &1.key.name)
      |> Enum.uniq()

    is_derived = super_class != nil
    has_explicit_ctor = Enum.any?(body, &match?(%AST.MethodDefinition{kind: :constructor}, &1))

    prev_derived = Process.get(:compiler_derived_ctor, false)
    prev_super = Process.get(:compiler_super_class)
    prev_priv = Process.get(:compiler_class_private_scope)
    prev_kinds = Process.get(:compiler_private_kinds)

    if is_derived and has_explicit_ctor do
      Process.put(:compiler_derived_ctor, true)
      Process.put(:compiler_super_class, super_class)
    end

    try do
      with {:loc, loc} <- callbacks.resolve.(scope, name),
           {:loc, proto_loc} <- callbacks.resolve.(scope, "<class_proto:#{name}>"),
           {:ok, ctor_fn} <-
             compile_class_ctor_with_private(body, name, field_names, scope, callbacks) do
        Process.put(:compiler_derived_ctor, prev_derived)
        Process.put(:compiler_super_class, prev_super)

        ctor_fn =
          if is_derived and has_explicit_ctor do
            %{ctor_fn | is_derived_class_constructor: true, super_call_allowed: true}
          else
            ctor_fn
          end

        flags = if is_derived, do: 1, else: 0

        parent =
          case super_class do
            %AST.Identifier{name: p} -> [{:get_var, p}]
            _ -> [:undefined]
          end

        private_fields =
          Enum.filter(body, &match?(%AST.FieldDefinition{key: %AST.PrivateIdentifier{}}, &1))

        private_methods =
          Enum.filter(body, fn
            %AST.MethodDefinition{key: %AST.PrivateIdentifier{}, kind: k}
            when k != :constructor ->
              true

            _ ->
              false
          end)

        field_names = Enum.map(private_fields, & &1.key.name) |> Enum.uniq()
        method_names = Enum.map(private_methods, & &1.key.name) |> Enum.uniq()

        private_kinds =
          Enum.reduce(private_methods, %{}, fn m, acc ->
            Map.put(acc, "##{m.key.name}", m.kind)
          end)

        instructions = instructions ++ [{:set_loc_uninitialized, loc}]

        # private_symbol for fields
        instructions =
          Enum.reduce(field_names, instructions, fn pn, instr ->
            case callbacks.resolve.(scope, "##{pn}") do
              {:loc, ploc} ->
                instr ++
                  [{:set_loc_uninitialized, ploc}, {:private_symbol, "##{pn}"}, {:put_loc, ploc}]

              _ ->
                instr
            end
          end)

        # init method locals
        instructions =
          Enum.reduce(method_names, instructions, fn pn, instr ->
            case callbacks.resolve.(scope, "##{pn}") do
              {:loc, ploc} -> instr ++ [{:set_loc_uninitialized, ploc}]
              _ -> instr
            end
          end)

        instructions =
          instructions ++
            parent ++
            [
              {:set_loc_uninitialized, proto_loc},
              {:constant, length(constants)},
              {:define_class, name, flags}
            ]

        constants = [ctor_fn | constants]

        # Set up private scope for method compilation
        private_locs =
          Enum.map(private_names, fn pn ->
            case callbacks.resolve.(scope, "##{pn}") do
              {:loc, l} -> l
              _ -> 0
            end
          end)

        private_refs =
          private_names |> Enum.with_index() |> Map.new(fn {pn, i} -> {"##{pn}", i} end)

        Process.put(:compiler_class_private_scope, {private_refs, private_locs})
        Process.put(:compiler_private_kinds, private_kinds)
        prev_vrefs = Process.get(:compiler_var_refs) || %{}

        Process.put(
          :compiler_var_refs,
          Enum.reduce(private_names, prev_vrefs, fn pn, a -> Map.put(a, "##{pn}", map_size(a)) end)
        )

        {methods, statics} = partition_class_body(body)

        result =
          with {:ok, instructions, constants} <-
                 emit_define_methods(methods, scope, instructions, constants, callbacks),
               {:ok, instructions, constants} <-
                 emit_private_methods(private_methods, scope, instructions, constants, callbacks) do
            close_privates =
              Enum.flat_map(private_names, fn pn ->
                case callbacks.resolve.(scope, "##{pn}") do
                  {:loc, l} -> [{:close_loc, l}]
                  _ -> []
                end
              end)

            instructions =
              instructions ++
                [
                  :undefined,
                  {:put_loc, proto_loc},
                  :drop,
                  {:set_loc, loc},
                  {:close_loc, proto_loc}
                ] ++
                close_privates ++ [{:put_var, name}]

            emit_define_statics(
              statics,
              loc,
              scope,
              instructions,
              constants,
              callbacks,
              name,
              super_class_name(super_class)
            )
          end

        result
      end
    after
      restore_process_value(:compiler_class_private_scope, prev_priv)
      restore_process_value(:compiler_private_kinds, prev_kinds)
      restore_process_value(:compiler_derived_ctor, prev_derived)
      restore_process_value(:compiler_super_class, prev_super)
    end
  end

  defp emit_private_methods([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp emit_private_methods([method | rest], scope, instructions, constants, callbacks) do
    pname = method.key.name

    case callbacks.resolve.(scope, "##{pname}") do
      {:loc, ploc} ->
        case callbacks.compile_function.(method.value, "##{pname}") do
          {:ok, function} ->
            instructions =
              instructions ++ [{:closure, length(constants)}, :set_home_object, {:put_loc, ploc}]

            emit_private_methods(rest, scope, instructions, [function | constants], callbacks)

          error ->
            error
        end

      _ ->
        {:error, {:unsupported, :class_element}}
    end
  end

  defp compile_class_ctor_with_private(body, name, [], _scope, callbacks) do
    compile_class_ctor(body, name, callbacks)
  end

  defp compile_class_ctor_with_private(body, name, private_names, scope, callbacks) do
    case Enum.find(body, &match?(%AST.MethodDefinition{kind: :constructor}, &1)) do
      %AST.MethodDefinition{} ->
        callbacks.compile_function.(hd(body).value, name)

      nil ->
        # Build constructor that inlines define_private_field for each private field
        private_locs =
          Enum.map(private_names, fn pn ->
            case callbacks.resolve.(scope, "##{pn}") do
              {:loc, l} -> l
              _ -> 0
            end
          end)

        field_inits =
          body
          |> Enum.filter(&match?(%AST.FieldDefinition{key: %AST.PrivateIdentifier{}}, &1))
          |> Enum.with_index()
          |> Enum.flat_map(fn {field, idx} ->
            val =
              case field.value do
                nil -> [:undefined]
                %AST.Literal{value: v} when is_integer(v) -> [{:push_int, v}]
                _ -> [:undefined]
              end

            [:push_this, {:get_var_ref_check, idx}] ++ val ++ [:define_private_field]
          end)

        closure_vars =
          Enum.zip(private_names, private_locs)
          |> Enum.map(fn {pn, ploc} ->
            %QuickBEAM.VM.ClosureVar{
              name: "##{pn}",
              var_idx: ploc,
              closure_type: 0,
              is_const: true,
              is_lexical: true,
              var_kind: 5
            }
          end)

        {:ok,
         QuickBEAM.JS.Compiler.FunctionBuilder.build(
           name: name,
           args: [],
           locals: [],
           closure_vars: closure_vars,
           constants: [],
           instructions: field_inits ++ [:return_undef],
           defined_arg_count: 0,
           has_prototype: true,
           has_simple_parameter_list: true,
           new_target_allowed: true,
           source: ""
         )}
    end
  end

  defp public_field_init_statements(body) do
    Enum.flat_map(body, fn
      %AST.FieldDefinition{static: false, computed: false, value: nil} ->
        []

      %AST.FieldDefinition{
        static: false,
        computed: false,
        key: %AST.Identifier{name: name},
        value: value
      } ->
        [
          %AST.ExpressionStatement{
            type: :expression_statement,
            expression: %AST.AssignmentExpression{
              type: :assignment_expression,
              operator: "=",
              left: %AST.MemberExpression{
                type: :member_expression,
                object: %AST.Identifier{type: :identifier, name: "this"},
                property: %AST.Identifier{type: :identifier, name: name},
                computed: false,
                optional: false
              },
              right: value
            }
          }
        ]

      _ ->
        []
    end)
  end

  defp compile_class_ctor(body, name, callbacks) do
    case Enum.find(body, &match?(%AST.MethodDefinition{kind: :constructor}, &1)) do
      %AST.MethodDefinition{value: v} ->
        callbacks.compile_function.(v, name)

      nil ->
        callbacks.compile_function.(
          %AST.FunctionExpression{
            type: :function_expression,
            id: nil,
            params: [],
            body: %AST.BlockStatement{
              type: :block_statement,
              body: public_field_init_statements(body)
            },
            async: false,
            generator: false
          },
          name
        )
    end
  end

  defp compile_catch_handler(
         param,
         %AST.BlockStatement{body: handler_body},
         scope,
         constants,
         opts,
         callbacks
       ) do
    case param do
      %AST.Identifier{name: name} ->
        case callbacks.resolve.(scope, name) do
          {:loc, loc} ->
            compile_non_tail(
              handler_body,
              scope,
              [{:put_loc, loc}],
              constants,
              opts,
              callbacks
            )

          _ ->
            {:error, {:unsupported, {:unresolved_identifier, name}}}
        end

      nil ->
        compile_non_tail(
          handler_body,
          scope,
          [:drop],
          constants,
          opts,
          callbacks
        )
    end
  end

  defp partition_class_body(body) do
    Enum.reduce(body, {[], []}, fn
      %AST.MethodDefinition{kind: :constructor}, acc -> acc
      %AST.MethodDefinition{key: %AST.PrivateIdentifier{}}, acc -> acc
      %AST.MethodDefinition{static: false} = m, {ms, ss} -> {[m | ms], ss}
      %AST.MethodDefinition{static: true} = m, {ms, ss} -> {ms, [m | ss]}
      %AST.FieldDefinition{static: true} = f, {ms, ss} -> {ms, [f | ss]}
      _, acc -> acc
    end)
    |> then(fn {m, s} -> {Enum.reverse(m), Enum.reverse(s)} end)
  end

  defp emit_define_methods([], _s, i, c, _cb), do: {:ok, i, c}

  defp emit_define_methods([m | rest], s, i, c, cb) do
    with {:ok, i, c} <- emit_define_method(m, s, i, c, cb),
         do: emit_define_methods(rest, s, i, c, cb)
  end

  defp emit_define_method(
         %AST.MethodDefinition{kind: k, computed: false, key: %AST.Identifier{name: n}, value: v},
         _s,
         i,
         c,
         cb
       ) do
    flags =
      case k do
        :get -> 1
        :set -> 2
        _ -> 0
      end

    with {:ok, f} <- cb.compile_function.(v, n) do
      home = if f.need_home_object, do: [:set_home_object], else: []
      {:ok, i ++ [{:closure, length(c)}] ++ home ++ [{:define_method, n, flags}], [f | c]}
    end
  end

  defp emit_define_method(
         %AST.MethodDefinition{kind: k, computed: true, key: key, value: v},
         s,
         i,
         c,
         cb
       ) do
    flags =
      case k do
        :get -> 1
        :set -> 2
        _ -> 0
      end

    with {:ok, i, c} <- cb.compile_expression.(key, s, i, c),
         {:ok, f} <- cb.compile_function.(v, nil) do
      {:ok, i ++ [:to_propkey, {:closure, length(c)}, {:define_method_computed, flags}], [f | c]}
    end
  end

  defp emit_define_method(_, _, _, _, _), do: {:error, {:unsupported, :class_element}}

  defp emit_define_statics([], _l, _s, i, c, _cb, _class_name, _super_name), do: {:ok, i, c}

  defp emit_define_statics([m | rest], l, s, i, c, cb, class_name, super_name) do
    with {:ok, i, c} <- emit_define_static(m, l, s, i, c, cb, class_name, super_name),
         do: emit_define_statics(rest, l, s, i, c, cb, class_name, super_name)
  end

  defp emit_define_static(
         %AST.MethodDefinition{
           static: true,
           computed: false,
           key: %AST.Identifier{name: n},
           value: v
         },
         l,
         _s,
         i,
         c,
         cb,
         _class_name,
         super_name
       ) do
    with {:ok, f} <- cb.compile_function.(rewrite_static_super(v, super_name), n),
         do:
           {:ok, i ++ [{:get_loc, l}, {:closure, length(c)}, {:define_method, n, 0}, :drop],
            [f | c]}
  end

  defp emit_define_static(
         %AST.MethodDefinition{static: true, computed: true, key: key, value: v},
         l,
         s,
         i,
         c,
         cb,
         _class_name,
         super_name
       ) do
    with {:ok, i, c} <- cb.compile_expression.(key, s, i ++ [{:get_loc, l}], c),
         {:ok, f} <- cb.compile_function.(rewrite_static_super(v, super_name), nil) do
      {:ok, i ++ [:to_propkey, {:closure, length(c)}, {:define_method_computed, 0}, :drop],
       [f | c]}
    end
  end

  defp emit_define_static(
         %AST.FieldDefinition{
           static: true,
           computed: false,
           key: %AST.Identifier{name: n},
           value: v
         },
         l,
         s,
         i,
         c,
         cb,
         class_name,
         _super_name
       ) do
    with {:ok, i, c} <-
           cb.compile_expression.(rewrite_static_this(v, class_name), s, i ++ [{:get_loc, l}], c),
         do: {:ok, i ++ [{:put_field, n}], c}
  end

  defp emit_define_static(_, _, _, _, _, _, _, _), do: {:error, {:unsupported, :class_element}}

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
         [
           {:get_var, class_name},
           {:closure, length(constants)},
           {:define_method, method_name, 0},
           :drop
         ], [function | constants]}
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
             rewrite_static_this(value, class_name),
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
      {:ok,
       instructions ++
         [:to_propkey, {:closure, length(constants)}, {:define_method_computed, 0}, :drop],
       [function | constants]}
    end
  end

  defp compile_static_member(_member, _name, _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, :class_element}}

  def class_factory_from_expression(name, super_class, body, _scope),
    do: class_factory(name, super_class, body)

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
           kind: kind,
           static: false,
           computed: computed,
           key: key,
           value: value
         },
         super_name
       )
       when kind in [:method, :get, :set] do
    property_kind = if kind == :method, do: :init, else: kind

    {:ok,
     [
       %AST.Property{
         type: :property,
         key: key,
         value: rewrite_super(value, super_name),
         kind: property_kind,
         method: false,
         shorthand: false,
         computed: computed
       }
     ]}
  end

  defp class_property(
         %AST.MethodDefinition{
           kind: kind,
           static: true,
           computed: computed,
           key: key,
           value: value
         },
         super_name
       )
       when kind in [:method, :get, :set] do
    property_kind = if kind == :method, do: :init, else: kind

    {:ok,
     [
       %AST.Property{
         type: :property,
         key: key,
         value: rewrite_static_super(value, super_name),
         kind: property_kind,
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

  defp rewrite_static_this(%AST.Identifier{name: "this"}, class_name),
    do: %AST.Identifier{type: :identifier, name: class_name}

  defp rewrite_static_this(
         %AST.MemberExpression{object: object, property: property} = expression,
         class_name
       ) do
    %{
      expression
      | object: rewrite_static_this(object, class_name),
        property: rewrite_static_this(property, class_name)
    }
  end

  defp rewrite_static_this(%{__struct__: _} = node, class_name) do
    updates =
      node
      |> Map.from_struct()
      |> Enum.map(fn
        {key, value} when is_list(value) ->
          {key, Enum.map(value, &rewrite_static_this(&1, class_name))}

        {key, value} ->
          {key, rewrite_static_this(value, class_name)}
      end)
      |> Map.new()

    struct(node, updates)
  end

  defp rewrite_static_this(value, _class_name), do: value

  defp rewrite_static_super(value, nil), do: value

  defp rewrite_static_super(%AST.FunctionExpression{body: body} = function, super_name),
    do: %{function | body: rewrite_static_super(body, super_name)}

  defp rewrite_static_super(%AST.BlockStatement{body: body} = block, super_name),
    do: %{block | body: Enum.map(body, &rewrite_static_super(&1, super_name))}

  defp rewrite_static_super(%AST.ReturnStatement{argument: argument} = statement, super_name),
    do: %{statement | argument: rewrite_static_super(argument, super_name)}

  defp rewrite_static_super(
         %AST.ExpressionStatement{expression: expression} = statement,
         super_name
       ),
       do: %{statement | expression: rewrite_static_super(expression, super_name)}

  defp rewrite_static_super(
         %AST.CallExpression{callee: callee, arguments: args} = expression,
         super_name
       ) do
    %{
      expression
      | callee: rewrite_static_super(callee, super_name),
        arguments: Enum.map(args, &rewrite_static_super(&1, super_name))
    }
  end

  defp rewrite_static_super(
         %AST.MemberExpression{object: %AST.Identifier{name: "super"}} = expression,
         super_name
       ) do
    %{expression | object: %AST.Identifier{type: :identifier, name: super_name}}
  end

  defp rewrite_static_super(
         %AST.MemberExpression{object: object, property: property} = expression,
         super_name
       ) do
    %{
      expression
      | object: rewrite_static_super(object, super_name),
        property: rewrite_static_super(property, super_name)
    }
  end

  defp rewrite_static_super(expression, _super_name), do: expression

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

  defp compile_iterator_for_of(
         body,
         value_loc,
         scope,
         instructions,
         constants,
         callbacks,
         tail?,
         bind_value_ops,
         inherited_opts
       ) do
    start_label = callbacks.unique_label.(:for_of_start)
    end_label = callbacks.unique_label.(:for_of_end)
    update_label = callbacks.unique_label.(:for_of_update)

    with {:loc, iter_loc} <- callbacks.resolve.(scope, "<for_of_array>"),
         {:loc, result_loc} <- callbacks.resolve.(scope, "<for_of_index>") do
      {init, loop_head} =
        for_of_iterator_setup(start_label, end_label, value_loc, iter_loc, result_loc)

      with {:ok, instructions, constants} <-
             compile(
               body,
               scope,
               instructions ++ init ++ loop_head ++ bind_value_ops,
               constants,
               loop_opts(
                 Keyword.merge(Keyword.take(inherited_opts, [:break_labels, :continue_labels]),
                   preserve_completion?: tail?
                 ),
                 tail?,
                 end_label,
                 update_label
               )
               |> Keyword.put(:iterator_close_loc, iter_loc),
               callbacks
             ) do
        instructions = maybe_drop_loop_completion(instructions, tail?)

        {:ok,
         instructions
         |> Kernel.++([{:label, update_label}, {:jump, start_label}, {:label, end_label}])
         |> maybe_push_loop_completion(tail?), constants}
      end
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
    end
  end

  defp compile_iterator_for_of_object_pattern(
         body,
         properties,
         value_loc,
         scope,
         instructions,
         constants,
         callbacks,
         tail?,
         inherited_opts
       ) do
    start_label = callbacks.unique_label.(:for_of_start)
    end_label = callbacks.unique_label.(:for_of_end)
    update_label = callbacks.unique_label.(:for_of_update)

    with {:loc, iter_loc} <- callbacks.resolve.(scope, "<for_of_array>"),
         {:loc, result_loc} <- callbacks.resolve.(scope, "<for_of_index>") do
      {init, loop_head} =
        for_of_iterator_setup(start_label, end_label, value_loc, iter_loc, result_loc)

      with {:ok, instructions, constants} <-
             compile_object_pattern(
               properties,
               scope,
               instructions ++ init ++ loop_head ++ [{:get_loc, value_loc}, :to_object],
               constants,
               callbacks
             ),
           {:ok, instructions, constants} <-
             compile(
               body,
               scope,
               instructions,
               constants,
               loop_opts(
                 Keyword.merge(Keyword.take(inherited_opts, [:break_labels, :continue_labels]),
                   preserve_completion?: tail?
                 ),
                 tail?,
                 end_label,
                 update_label
               )
               |> Keyword.put(:iterator_close_loc, iter_loc),
               callbacks
             ) do
        instructions = maybe_drop_loop_completion(instructions, tail?)

        {:ok,
         instructions
         |> Kernel.++([{:label, update_label}, {:jump, start_label}, {:label, end_label}])
         |> maybe_push_loop_completion(tail?), constants}
      end
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
    end
  end

  defp compile_iterator_for_of_destructuring(
         body,
         elements,
         value_loc,
         scope,
         instructions,
         constants,
         callbacks,
         tail?,
         inherited_opts
       ) do
    start_label = callbacks.unique_label.(:for_of_start)
    end_label = callbacks.unique_label.(:for_of_end)
    update_label = callbacks.unique_label.(:for_of_update)

    with {:loc, iter_loc} <- callbacks.resolve.(scope, "<for_of_array>"),
         {:loc, result_loc} <- callbacks.resolve.(scope, "<for_of_index>") do
      {init, loop_head} =
        for_of_iterator_setup(start_label, end_label, value_loc, iter_loc, result_loc)

      with {:ok, instructions, constants} <-
             compile_array_pattern(
               elements,
               scope,
               instructions ++ init ++ loop_head ++ [{:get_loc, value_loc}],
               constants,
               callbacks
             ),
           {:ok, instructions, constants} <-
             compile(
               body,
               scope,
               instructions,
               constants,
               loop_opts(
                 Keyword.merge(Keyword.take(inherited_opts, [:break_labels, :continue_labels]),
                   preserve_completion?: tail?
                 ),
                 tail?,
                 end_label,
                 update_label
               )
               |> Keyword.put(:iterator_close_loc, iter_loc),
               callbacks
             ) do
        instructions = maybe_drop_loop_completion(instructions, tail?)

        {:ok,
         instructions
         |> Kernel.++([{:label, update_label}, {:jump, start_label}, {:label, end_label}])
         |> maybe_push_loop_completion(tail?), constants}
      end
    else
      :error -> {:error, {:unsupported, :for_of_binding}}
    end
  end

  defp iterator_close_ops(opts) do
    case Keyword.get(opts, :iterator_close_loc) do
      nil -> []
      iter_loc -> [{:get_loc, iter_loc}, :undefined, :undefined, :iterator_close]
    end
  end

  defp non_tail_control_opts(opts) do
    opts
    |> Keyword.take([
      :break_labels,
      :continue_labels,
      :break_label,
      :continue_label,
      :preserve_completion?
    ])
    |> Keyword.put(:tail?, false)
  end

  defp loop_opts(opts, tail?, break_label, continue_label, label \\ nil) do
    opts
    |> Keyword.take([:break_labels, :continue_labels, :preserve_completion?])
    |> Keyword.put(:tail?, tail?)
    |> Keyword.put(:break_label, break_label)
    |> Keyword.put(:continue_label, continue_label)
    |> maybe_put_labeled_loop(label, break_label, continue_label)
  end

  defp maybe_put_labeled_loop(opts, nil, _break_label, _continue_label), do: opts

  defp maybe_put_labeled_loop(opts, label, break_label, continue_label) do
    break_labels = opts |> Keyword.get(:break_labels, %{}) |> Map.put(label, break_label)
    continue_labels = opts |> Keyword.get(:continue_labels, %{}) |> Map.put(label, continue_label)

    opts
    |> Keyword.put(:break_labels, break_labels)
    |> Keyword.put(:continue_labels, continue_labels)
  end

  defp resolve_jump_label(opts, default_key, _labeled_key, nil),
    do: Keyword.fetch(opts, default_key)

  defp resolve_jump_label(opts, _default_key, labeled_key, %AST.Identifier{name: name}) do
    case Keyword.get(opts, labeled_key, %{}) do
      %{^name => label} -> {:ok, label}
      _ -> :error
    end
  end

  defp maybe_reset_loop_completion(instructions, false), do: instructions

  defp maybe_reset_loop_completion(instructions, true),
    do: instructions ++ [:undefined, {:set_loc, 0}, :drop]

  defp maybe_drop_loop_completion(instructions, false), do: instructions
  defp maybe_drop_loop_completion(instructions, true), do: instructions ++ [:drop]

  defp maybe_push_loop_completion(instructions, false), do: instructions
  defp maybe_push_loop_completion(instructions, true), do: instructions ++ [{:get_loc, 0}]

  defp compile_do_while(body, test, scope, instructions, constants, opts, callbacks, label) do
    start_label = callbacks.unique_label.(:do_start)
    test_label = callbacks.unique_label.(:do_test)
    end_label = callbacks.unique_label.(:do_end)

    tail? = Keyword.fetch!(opts, :tail?)
    instructions = maybe_reset_loop_completion(instructions, tail?)

    with {:ok, instructions, constants} <-
           compile(
             body,
             scope,
             instructions ++ [{:label, start_label}],
             constants,
             loop_opts(
               Keyword.put(opts, :preserve_completion?, tail?),
               tail?,
               end_label,
               test_label,
               label
             ),
             callbacks
           ),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(
             test,
             scope,
             instructions ++ [{:label, test_label}],
             constants
           ) do
      instructions = maybe_drop_loop_completion(instructions, tail?)

      {:ok,
       instructions
       |> Kernel.++([{:jump_if_true, start_label}, {:label, end_label}])
       |> maybe_push_loop_completion(tail?), constants}
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
      compile_object_pattern(
        properties,
        scope,
        instructions ++ [:to_object],
        constants,
        callbacks
      )
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

  defp compile_object_pattern(properties, scope, instructions, constants, callbacks),
    do: compile_object_pattern(properties, scope, instructions, constants, callbacks, [])

  defp compile_object_pattern([], _scope, instructions, constants, _callbacks, _excluded),
    do: {:ok, instructions ++ [:drop], constants}

  defp compile_object_pattern(
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
               compile_object_rest_excluded_keys(
                 excluded,
                 scope,
                 instructions,
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

  defp compile_object_pattern(
         [%AST.SpreadElement{} = rest],
         scope,
         instructions,
         constants,
         callbacks,
         excluded
       ),
       do: compile_object_pattern_rest(rest, scope, instructions, constants, callbacks, excluded)

  defp compile_object_pattern([property], scope, instructions, constants, callbacks, _excluded),
    do:
      compile_object_pattern_property(property, scope, instructions, constants, callbacks, false)

  defp compile_object_pattern(
         [property | rest],
         scope,
         instructions,
         constants,
         callbacks,
         excluded
       ) do
    excluded_key = object_pattern_property_key(property, length(excluded))

    with {:ok, instructions, constants} <-
           compile_object_pattern_property(
             property,
             scope,
             instructions,
             constants,
             callbacks,
             true,
             excluded_key
           ) do
      compile_object_pattern(
        rest,
        scope,
        instructions,
        constants,
        callbacks,
        excluded ++ [excluded_key]
      )
    end
  end

  defp compile_object_pattern_property(
         property,
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?
       ),
       do:
         compile_object_pattern_property(
           property,
           scope,
           instructions,
           constants,
           callbacks,
           keep_object?,
           nil
         )

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
         keep_object?,
         _excluded_key
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
         %AST.Property{
           computed: false,
           key: %AST.Identifier{name: key},
           value: %AST.AssignmentPattern{
             left: %AST.Identifier{name: name},
             right: default_expr
           }
         },
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?,
         _excluded_key
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} ->
        prefix = if keep_object?, do: [:dup], else: []
        done_label = callbacks.unique_label.(:default_done)

        with {:ok, default_instructions, constants} <-
               callbacks.compile_expression.(default_expr, scope, [], constants) do
          {:ok,
           instructions ++
             prefix ++
             [
               {:get_field, key},
               :dup,
               :undefined,
               :strict_eq,
               {:jump_if_false, done_label},
               :drop
             ] ++
             default_instructions ++ [{:label, done_label}, {:put_loc, loc}], constants}
        end

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_object_pattern_property(
         %AST.Property{
           computed: false,
           key: %AST.Literal{value: key},
           value: %AST.Identifier{name: name}
         },
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?,
         excluded_key
       ) do
    compile_object_pattern_property(
      %AST.Property{
        computed: false,
        key: %AST.Identifier{name: to_string(key)},
        value: %AST.Identifier{name: name}
      },
      scope,
      instructions,
      constants,
      callbacks,
      keep_object?,
      excluded_key
    )
  end

  defp compile_object_pattern_property(
         %AST.Property{
           computed: true,
           key: computed_key,
           value: %AST.Identifier{name: name}
         },
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?,
         excluded_key
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} ->
        prefix = if keep_object?, do: [:dup], else: []

        suffix =
          cond do
            keep_object? and match?({:computed_temp, _}, excluded_key) ->
              {:computed_temp, temp_name} = excluded_key
              {:loc, temp_loc} = callbacks.resolve.(scope, temp_name)
              [:to_propkey, :dup, {:put_loc, temp_loc}, :get_array_el2, {:put_loc, loc}, :drop]

            keep_object? ->
              [:to_propkey, :get_array_el2, {:put_loc, loc}, :drop]

            true ->
              [:to_propkey, :get_array_el, {:put_loc, loc}]
          end

        with {:ok, instructions, constants} <-
               callbacks.compile_expression.(
                 computed_key,
                 scope,
                 instructions ++ prefix,
                 constants
               ) do
          {:ok, instructions ++ suffix, constants}
        end

      :error ->
        {:error, {:unsupported, {:unresolved_identifier, name}}}
    end
  end

  defp compile_object_pattern_property(
         %AST.Property{
           computed: false,
           key: %AST.Identifier{name: key},
           value: %AST.ObjectPattern{properties: nested}
         },
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?,
         _excluded_key
       ) do
    prefix = if keep_object?, do: [:dup], else: []

    compile_object_pattern(
      nested,
      scope,
      instructions ++ prefix ++ [{:get_field, key}, :to_object],
      constants,
      callbacks
    )
  end

  defp compile_object_pattern_property(
         %AST.Property{
           computed: false,
           key: %AST.Identifier{name: key},
           value: %AST.ArrayPattern{elements: nested}
         },
         scope,
         instructions,
         constants,
         callbacks,
         keep_object?,
         _excluded_key
       ) do
    prefix = if keep_object?, do: [:dup], else: []

    compile_array_pattern(
      nested,
      scope,
      instructions ++ prefix ++ [{:get_field, key}],
      constants,
      callbacks
    )
  end

  defp compile_object_pattern_property(
         %AST.Property{} = property,
         _scope,
         _instructions,
         _constants,
         _callbacks,
         _keep_object?,
         _excluded_key
       ),
       do: {:error, {:unsupported, {:object_pattern_property, property.type}}}

  defp compile_object_pattern_rest(
         %AST.SpreadElement{argument: %AST.Identifier{name: name}},
         scope,
         instructions,
         constants,
         callbacks,
         excluded
       ) do
    case callbacks.resolve.(scope, name) do
      {:loc, loc} ->
        with {:ok, instructions, constants} <-
               compile_object_rest_excluded_keys(
                 excluded,
                 scope,
                 instructions,
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

  defp compile_object_rest_excluded_keys([], _scope, instructions, constants, _callbacks),
    do: {:ok, instructions, constants}

  defp compile_object_rest_excluded_keys([key | rest], scope, instructions, constants, callbacks) do
    with {:ok, instructions, constants} <-
           compile_object_rest_excluded_key(key, scope, instructions, constants, callbacks) do
      compile_object_rest_excluded_keys(rest, scope, instructions, constants, callbacks)
    end
  end

  defp compile_object_rest_excluded_key(
         {:computed_temp, temp_name},
         scope,
         instructions,
         constants,
         callbacks
       ) do
    case callbacks.resolve.(scope, temp_name) do
      {:loc, loc} -> {:ok, instructions ++ [{:get_loc, loc}], constants}
      :error -> {:error, {:unsupported, {:unresolved_identifier, temp_name}}}
    end
  end

  defp compile_object_rest_excluded_key(key, _scope, instructions, constants, _callbacks) do
    {key_instr, constants} = add_constant(key, constants)
    {:ok, instructions ++ [key_instr], constants}
  end

  defp object_pattern_property_key(%AST.Property{computed: true}, index),
    do: {:computed_temp, object_rest_computed_key_temp(index)}

  defp object_pattern_property_key(%AST.Property{key: %AST.Identifier{name: key}}, _index),
    do: key

  defp object_pattern_property_key(%AST.Property{key: %AST.Literal{value: key}}, _index),
    do: to_string(key)

  defp object_rest_computed_key_temp(index), do: "<object_rest_key:#{index}>"

  defp compile_return(
         %AST.ReturnStatement{argument: nil},
         _scope,
         instructions,
         constants,
         opts,
         _callbacks
       ) do
    instructions = instructions ++ [:undefined] ++ iterator_close_ops(opts)

    case Keyword.get(opts, :finally_label) do
      nil ->
        {:ok, instructions ++ [:return], constants}

      label ->
        {:ok, instructions ++ [:nip_catch, {:gosub, label}, :return], constants}
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
      is_derived = Process.get(:compiler_derived_ctor, false)

      ret_ops =
        if is_derived do
          done_label = callbacks.unique_label.(:ctor_ret_done)

          [
            :check_ctor_return,
            {:jump_if_false, done_label},
            :drop,
            :push_this,
            {:label, done_label},
            :return
          ]
        else
          [:return]
        end

      instructions = instructions ++ iterator_close_ops(opts)

      case Keyword.get(opts, :finally_label) do
        nil -> {:ok, instructions ++ ret_ops, constants}
        label -> {:ok, instructions ++ [:nip_catch, {:gosub, label}] ++ ret_ops, constants}
      end
    end
  end

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp enter_block_scope(scope) do
    case Process.get(:compiler_block_scopes, []) do
      [%{bindings: bindings} | rest] ->
        Process.put(:compiler_block_scopes, rest)

        Enum.reduce(bindings, scope, fn {name, hidden_name, kind}, acc ->
          Scope.alias_local(acc, name, hidden_name, kind)
        end)

      [] ->
        scope
    end
  end

  defp for_of_iterator_setup(start_label, end_label, value_loc, iter_loc, result_loc) do
    init = [
      :dup,
      {:get_var, "Symbol"},
      {:get_field, "iterator"},
      :get_array_el2,
      {:call_method, 0},
      {:put_loc, iter_loc},
      :drop
    ]

    loop_head = [
      {:label, start_label},
      {:get_loc, iter_loc},
      :dup,
      {:get_field, "next"},
      {:call_method, 0},
      {:put_loc, result_loc},
      {:get_loc, result_loc},
      {:get_field, "done"},
      {:jump_if_true, end_label},
      {:get_loc, result_loc},
      {:get_field, "value"},
      {:put_loc, value_loc}
    ]

    {init, loop_head}
  end
end
