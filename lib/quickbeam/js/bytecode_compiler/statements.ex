defmodule QuickBEAM.JS.BytecodeCompiler.Statements do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.Slots
  alias QuickBEAM.JS.Parser.AST

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
            left: %AST.MemberExpression{
              object: object,
              property: %AST.Identifier{name: property},
              computed: false
            },
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
           callbacks.compile_expression.(object, scope, instructions, constants),
         {:ok, instructions, constants} <-
           callbacks.compile_expression.(right, scope, instructions, constants) do
      if Keyword.fetch!(opts, :tail?) do
        {:ok, instructions ++ [:insert2, {:put_field, property}, {:set_loc, 0}], constants}
      else
        {:ok, instructions ++ property_assignment_statement_suffix(callbacks, scope, property),
         constants}
      end
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

  defp property_assignment_statement_suffix(callbacks, scope, property) do
    case callbacks.resolve.(scope, "<ret>") do
      {:loc, 0} -> [:insert2, {:put_field, property}, {:put_loc, 0}]
      _ -> [{:put_field, property}]
    end
  end
end
