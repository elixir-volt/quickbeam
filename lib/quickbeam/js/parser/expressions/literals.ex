defmodule QuickBEAM.JS.Parser.Expressions.Literals do
  @moduledoc "Literal, object, array, property, and meta-expression grammar."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Lexer, Token, Validation}

      defp parse_private_identifier_expression(state) do
        parse_private_identifier_from_hash(state)
      end

      defp parse_private_identifier_from_hash(state) do
        hash = current(state)
        state = advance(state)
        token = current(state)

        if private_identifier_token?(hash, token) do
          {%AST.PrivateIdentifier{name: token.value}, advance(state)}
        else
          {%AST.PrivateIdentifier{name: ""}, add_error(state, token, "expected private name")}
        end
      end

      defp parse_import_meta_expression(state) do
        meta = %AST.Identifier{name: "import"}
        state = state |> advance() |> expect_value(".")
        {property, state} = parse_binding_identifier(state)
        {%AST.MetaProperty{meta: meta, property: property}, state}
      end

      defp parse_new_target_expression(state) do
        meta = %AST.Identifier{name: "new"}
        state = state |> advance() |> expect_value(".")
        {property, state} = parse_binding_identifier(state)
        {%AST.MetaProperty{meta: meta, property: property}, state}
      end

      defp parse_new_expression(state) do
        state = advance(state)
        {callee, state} = parse_prefix(state)

        {arguments, state} =
          if match_value?(state, "(") do
            parse_arguments(advance(state), [])
          else
            {[], state}
          end

        {%AST.NewExpression{callee: callee, arguments: arguments}, state}
      end

      defp parse_array_expression(state) do
        state = advance(state)
        {elements, state} = parse_array_elements(state, [])
        {%AST.ArrayExpression{elements: elements}, state}
      end

      defp parse_array_elements(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc), add_error(state, current(state), "unterminated array literal")}

          match_value?(state, "]") ->
            {Enum.reverse(acc), advance(state)}

          match_value?(state, ",") ->
            parse_array_elements(advance(state), [nil | acc])

          match_value?(state, "...") ->
            state = advance(state)
            {argument, state} = parse_expression(state, 2)
            element = %AST.SpreadElement{argument: argument}

            cond do
              match_value?(state, ",") and peek_value(state) == "]" ->
                parse_array_elements(advance(state), [nil, element | acc])

              match_value?(state, ",") ->
                parse_array_elements(advance(state), [element | acc])

              match_value?(state, "]") ->
                {Enum.reverse([element | acc]), advance(state)}

              true ->
                {Enum.reverse([element | acc]), expect_value(state, "]")}
            end

          true ->
            {element, state} = parse_expression(state, 2)

            cond do
              match_value?(state, ",") -> parse_array_elements(advance(state), [element | acc])
              match_value?(state, "]") -> {Enum.reverse([element | acc]), advance(state)}
              true -> {Enum.reverse([element | acc]), expect_value(state, "]")}
            end
        end
      end

      defp parse_object_expression(state) do
        state = advance(state)
        {properties, state} = parse_object_properties(state, [])
        {%AST.ObjectExpression{properties: properties}, state}
      end

      defp parse_object_properties(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc), add_error(state, current(state), "unterminated object literal")}

          match_value?(state, "}") ->
            {Enum.reverse(acc), advance(state)}

          true ->
            {property, state} = parse_object_property(state)

            cond do
              match_value?(state, ",") ->
                parse_object_properties(advance(state), [property | acc])

              match_value?(state, "}") ->
                {Enum.reverse([property | acc]), advance(state)}

              true ->
                {Enum.reverse([property | acc]), expect_value(state, "}")}
            end
        end
      end

      defp parse_object_property(state) do
        cond do
          match_value?(state, "...") ->
            state = advance(state)
            {argument, state} = parse_expression(state, 2)
            {%AST.SpreadElement{argument: argument}, state}

          async_method_start?(state) ->
            parse_async_object_method(state)

          match_value?(state, "*") ->
            parse_generator_object_method(state)

          unescaped_match_value?(state, ["get", "set"]) and accessor_key_start?(state) ->
            parse_accessor_property(state)

          true ->
            parse_regular_object_property(state)
        end
      end

      defp unescaped_match_value?(state, values) when is_list(values) do
        token = current(state)
        token.value in values and token.raw == token.value
      end

      defp parse_generator_object_method(state) do
        state = advance(state)
        {key, computed?, state} = parse_property_key_with_computed(state)
        await_allowed? = state.await_allowed?
        state = %{state | await_allowed?: false}
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, true, false)
        state = %{state | await_allowed?: await_allowed?}

        state =
          state
          |> Validation.validate_unique_params(params)
          |> validate_object_method_super_call_params(params)
          |> Validation.validate_generator_params(true, params)
          |> Validation.validate_generator_body_bindings(true, body)
          |> Validation.validate_strict_function_params(params, body)

        value = %AST.FunctionExpression{
          id: property_function_name(key),
          params: params,
          body: body,
          generator: true
        }

        {%AST.Property{key: key, value: value, method: true, computed: computed?}, state}
      end

      defp parse_async_object_method(state) do
        state = advance(state)
        {generator?, state} = consume_generator_marker(state)
        {key, computed?, state} = parse_property_key_with_computed(state)
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, generator?, true)

        state =
          state
          |> Validation.validate_unique_params(params)
          |> validate_object_method_super_call_params(params)
          |> Validation.validate_async_params(true, params)
          |> Validation.validate_async_body_bindings(true, body)
          |> Validation.validate_generator_params(generator?, params)
          |> Validation.validate_generator_body_bindings(generator?, body)
          |> Validation.validate_strict_function_params(params, body)

        value = %AST.FunctionExpression{
          id: property_function_name(key),
          params: params,
          body: body,
          async: true,
          generator: generator?
        }

        {%AST.Property{key: key, value: value, method: true, computed: computed?}, state}
      end

      defp parse_regular_object_property(state) do
        {key, computed?, state} = parse_property_key_with_computed(state)

        cond do
          match_value?(state, ":") ->
            state = advance(state)
            {value, state} = parse_expression(state, 2)
            {%AST.Property{key: key, value: value, computed: computed?}, state}

          match_value?(state, "(") ->
            await_allowed? = state.await_allowed?
            state = %{state | await_allowed?: false}
            {params, state} = parse_formal_parameters(state)
            {body, state} = parse_function_body(state, false, false)
            state = %{state | await_allowed?: await_allowed?}

            state =
              state
              |> Validation.validate_unique_params(params)
              |> validate_object_method_super_call_params(params)
              |> Validation.validate_strict_function_params(params, body)

            value = %AST.FunctionExpression{
              id: property_function_name(key),
              params: params,
              body: body
            }

            {%AST.Property{key: key, value: value, method: true, computed: computed?}, state}

          match?(%AST.Identifier{}, key) and match_value?(state, "=") ->
            state = advance(state)
            {right, state} = parse_expression(state, 2)
            value = %AST.AssignmentPattern{left: key, right: right}
            {%AST.Property{key: key, value: value, shorthand: true, computed: computed?}, state}

          match?(%AST.Identifier{}, key) ->
            state = validate_object_shorthand(state, key, computed?)
            {%AST.Property{key: key, value: key, shorthand: true, computed: computed?}, state}

          true ->
            {%AST.Property{key: key, value: key, shorthand: true, computed: computed?}, state}
        end
      end

      defp validate_object_shorthand(state, _key, true),
        do: add_error(state, current(state), "invalid object shorthand")

      defp validate_object_shorthand(
             %{await_allowed?: true} = state,
             %AST.Identifier{name: "await"},
             false
           ),
           do: add_error(state, current(state), "invalid object shorthand")

      defp validate_object_shorthand(
             %{yield_allowed?: true} = state,
             %AST.Identifier{name: "yield"},
             false
           ),
           do: add_error(state, current(state), "invalid object shorthand")

      defp validate_object_shorthand(state, _key, _computed?), do: state

      defp parse_accessor_property(state) do
        kind = current(state).value |> String.to_atom()
        state = advance(state)
        {key, computed?, state} = parse_property_key_with_computed(state)
        await_allowed? = state.await_allowed?
        state = %{state | await_allowed?: false}
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, false, false)
        state = %{state | await_allowed?: await_allowed?}

        state =
          state
          |> validate_accessor_arity(kind, params)
          |> Validation.validate_strict_function_params(params, body)

        value = %AST.FunctionExpression{
          id: property_function_name(key),
          params: params,
          body: body
        }

        {%AST.Property{key: key, value: value, kind: kind, computed: computed?}, state}
      end

      defp parse_property_key(state) do
        {key, _computed?, state} = parse_property_key_with_computed(state)
        {key, state}
      end

      defp validate_object_method_super_call_params(state, params) do
        if Enum.any?(params, &super_call_param?/1) do
          add_error(state, current(state), "super not allowed outside class method")
        else
          state
        end
      end

      defp super_call_param?(%AST.AssignmentPattern{right: right}), do: super_call_param?(right)

      defp super_call_param?(%AST.CallExpression{callee: %AST.Identifier{name: "super"}}),
        do: true

      defp super_call_param?(%AST.CallExpression{arguments: arguments}),
        do: Enum.any?(arguments, &super_call_param?/1)

      defp super_call_param?(%AST.ArrayPattern{elements: elements}),
        do: Enum.any?(elements, &super_call_param?/1)

      defp super_call_param?(%AST.ObjectPattern{properties: properties}),
        do: Enum.any?(properties, &super_call_param?/1)

      defp super_call_param?(%AST.Property{value: value}), do: super_call_param?(value)

      defp super_call_param?(%AST.RestElement{argument: argument}),
        do: super_call_param?(argument)

      defp super_call_param?(_param), do: false

      defp validate_accessor_arity(state, :get, []), do: state
      defp validate_accessor_arity(state, :set, [_param]), do: state

      defp validate_accessor_arity(state, _kind, _params),
        do: add_error(state, current(state), "invalid number of arguments for getter or setter")

      defp parse_property_key_with_computed(state) do
        token = current(state)

        cond do
          match_value?(state, "[") ->
            state = advance(state)
            {key, state} = parse_expression(state, 0)
            {key, true, expect_value(state, "]")}

          token.type == :identifier ->
            {%AST.Identifier{name: token.value}, false, advance(state)}

          token.type == :keyword ->
            {%AST.Identifier{name: token.value}, false, advance(state)}

          token.type == :string ->
            {%AST.Literal{value: token.value, raw: token.raw}, false, advance(state)}

          token.type == :number ->
            {%AST.Literal{value: token.value, raw: token.raw}, false, advance(state)}

          token.type in [:boolean, :null] ->
            {%AST.Identifier{name: token.raw}, false, advance(state)}

          true ->
            {%AST.Identifier{name: ""}, false,
             add_error(state, token, "expected property key") |> advance()}
        end
      end

      defp property_function_name(%AST.Identifier{} = id), do: id
      defp property_function_name(_), do: nil

      defp parse_yield_expression(state) do
        state = advance(state)

        cond do
          match_value?(state, "*") and current(state).before_line_terminator? ->
            {%AST.YieldExpression{},
             add_error(state, current(state), "yield delegate cannot start after line terminator")}

          eof?(state) or current(state).before_line_terminator? or statement_end?(state) or
              match_value?(state, [",", "]", ")", ":"]) ->
            {%AST.YieldExpression{}, state}

          match_value?(state, "*") ->
            state = advance(state)
            {argument, state} = parse_expression(state, 0)
            {%AST.YieldExpression{argument: argument, delegate: true}, state}

          true ->
            {argument, state} = parse_expression(state, 2)
            {%AST.YieldExpression{argument: argument}, state}
        end
      end

      defp parse_await_expression(state) do
        state = advance(state)
        {argument, state} = parse_prefix(state)
        {argument, state} = parse_postfix_tail(state, argument)
        {%AST.AwaitExpression{argument: argument}, state}
      end

      defp parse_property_identifier(state) do
        token = current(state)

        cond do
          match_value?(state, "#") ->
            parse_private_identifier_from_hash(state)

          token.type in [:identifier, :keyword, :boolean, :null] ->
            {%AST.Identifier{name: to_string(token.value)}, advance(state)}

          true ->
            {%AST.Identifier{name: ""}, add_error(state, token, "expected property name")}
        end
      end
    end
  end
end
