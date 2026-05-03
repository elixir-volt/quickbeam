defmodule QuickBEAM.JS.BytecodeCompiler.Expressions do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler.{Emitter, Operators, Slots}
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

  def compile(%AST.Identifier{name: name}, scope, instructions, constants, callbacks) do
    case callbacks.resolve.(scope, name) do
      :error -> {:error, {:unsupported, {:unresolved_identifier, name}}}
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

  def compile(%AST.FunctionExpression{} = expression, _scope, instructions, constants, callbacks) do
    with {:ok, function} <- callbacks.compile_function.(expression, function_name(expression.id)) do
      {:ok, instructions ++ [{:closure, length(constants)}], [function | constants]}
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
    with {:ok, instructions, constants} <-
           callbacks.compile_expression.(callee, scope, instructions, constants),
         {:ok, instructions, constants} <-
           compile_call_args(args, scope, instructions, constants, callbacks) do
      {:ok, instructions ++ [{:call, length(args)}], constants}
    end
  end

  def compile(expression, _scope, _instructions, _constants, _callbacks),
    do: {:error, {:unsupported, expression.type}}

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
