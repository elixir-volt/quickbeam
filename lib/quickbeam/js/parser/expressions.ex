defmodule QuickBEAM.JS.Parser.Expressions do
  @moduledoc "Expression grammar for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp parse_function_expression(state) do
        {async?, state} = consume_async_modifier(state)
        state = expect_keyword(state, "function")
        {generator?, state} = consume_generator_marker(state)

        {id, state} =
          if identifier_like?(current(state)) do
            parse_binding_identifier(state)
          else
            {nil, state}
          end

        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, generator?, async?)

        state =
          state
          |> Validation.validate_async_params(async?, params)
          |> Validation.validate_generator_params(generator?, params)
          |> Validation.validate_strict_function_name(id, body)
          |> Validation.validate_strict_function_params(params, body)

        {%AST.FunctionExpression{
           id: id,
           params: params,
           body: body,
           async: async?,
           generator: generator?
         }, state}
      end

      defp parse_expression_statement(state) do
        {expr, state} = parse_expression(state, 0)
        {%AST.ExpressionStatement{expression: expr}, consume_semicolon(state)}
      end

      defp parse_expression(state, min_precedence) do
        {left, state} = parse_prefix(state)
        parse_expression_tail(state, left, min_precedence)
      end

      defp parse_expression_tail(state, left, min_precedence) do
        state = parse_postfix_tail(state, left)

        case state do
          {left, state} -> parse_binary_tail(state, left, min_precedence)
        end
      end

      defp parse_postfix_tail(state, left) do
        cond do
          match_value?(state, "(") ->
            {arguments, state} = parse_arguments(advance(state), [])
            parse_postfix_tail(state, %AST.CallExpression{callee: left, arguments: arguments})

          match_value?(state, "?.") ->
            state =
              if match?(%AST.NewExpression{}, left),
                do: add_error(state, current(state), "optional chain not allowed after new"),
                else: state

            parse_optional_chain_tail(advance(state), left)

          match_value?(state, ".") ->
            state = advance(state)
            {property, state} = parse_property_identifier(state)

            parse_postfix_tail(state, %AST.MemberExpression{
              object: left,
              property: property,
              computed: false
            })

          match_value?(state, "[") ->
            state = advance(state)
            {property, state} = parse_expression(state, 0)
            state = expect_value(state, "]")

            parse_postfix_tail(state, %AST.MemberExpression{
              object: left,
              property: property,
              computed: true
            })

          current(state).type == :template ->
            state =
              if optional_chain?(left),
                do:
                  add_error(
                    state,
                    current(state),
                    "optional chain not allowed as tagged template callee"
                  ),
                else: state

            quasi = parse_template_literal(current(state))

            parse_postfix_tail(advance(state), %AST.TaggedTemplateExpression{
              tag: left,
              quasi: quasi
            })

          postfix_update_operator?(current(state)) ->
            token = current(state)
            state = Validation.validate_update_target(state, left)

            {%AST.UpdateExpression{operator: token.value, argument: left, prefix: false},
             advance(state)}

          true ->
            {left, state}
        end
      end

      defp parse_optional_chain_tail(state, left) do
        state = Validation.validate_optional_chain_base(state, left)

        cond do
          match_value?(state, "(") ->
            {arguments, state} = parse_arguments(advance(state), [])

            parse_postfix_tail(state, %AST.CallExpression{
              callee: left,
              arguments: arguments,
              optional: true
            })

          match_value?(state, "[") ->
            state = advance(state)
            {property, state} = parse_expression(state, 0)
            state = expect_value(state, "]")

            parse_postfix_tail(state, %AST.MemberExpression{
              object: left,
              property: property,
              computed: true,
              optional: true
            })

          true ->
            {property, state} = parse_property_identifier(state)

            parse_postfix_tail(state, %AST.MemberExpression{
              object: left,
              property: property,
              computed: false,
              optional: true
            })
        end
      end

      defp parse_binary_tail(state, left, min_precedence) do
        token = current(state)
        operator = operator_value(token)

        case Map.get(@precedence, operator) do
          {precedence, associativity} when precedence >= min_precedence ->
            state = advance(state)

            if operator == "?" do
              parse_conditional_tail(state, left, precedence)
            else
              next_min = if associativity == :left, do: precedence + 1, else: precedence
              {right, state} = parse_expression(state, next_min)
              state = Validation.validate_assignment_target(state, operator, left)
              expr = binary_node(operator, left, right)
              parse_binary_tail(state, expr, min_precedence)
            end

          _ ->
            {left, state}
        end
      end

      defp private_identifier_start?(%Token{type: :punctuator, value: "#"}), do: true
      defp private_identifier_start?(_token), do: false

      defp prefix_update_operator?(%Token{type: :punctuator, value: value})
           when value in @update_ops,
           do: true

      defp prefix_update_operator?(_token), do: false

      defp postfix_update_operator?(%Token{
             type: :punctuator,
             value: value,
             before_line_terminator?: false
           })
           when value in @update_ops,
           do: true

      defp postfix_update_operator?(_token), do: false

      defp unary_operator?(%Token{type: :punctuator, value: value})
           when value in ["!", "~", "+", "-"],
           do: true

      defp unary_operator?(%Token{type: :keyword, value: value})
           when value in ["typeof", "void", "delete"],
           do: true

      defp unary_operator?(_token), do: false

      defp optional_chain?(%AST.MemberExpression{optional: true}), do: true
      defp optional_chain?(%AST.CallExpression{optional: true}), do: true
      defp optional_chain?(%AST.MemberExpression{object: object}), do: optional_chain?(object)
      defp optional_chain?(%AST.CallExpression{callee: callee}), do: optional_chain?(callee)

      defp optional_chain?(%AST.ObjectExpression{properties: properties}),
        do: Enum.any?(properties, &optional_chain?/1)

      defp optional_chain?(%AST.ObjectPattern{properties: properties}),
        do: Enum.any?(properties, &optional_chain?/1)

      defp optional_chain?(%AST.ArrayExpression{elements: elements}),
        do: Enum.any?(elements, &optional_chain?/1)

      defp optional_chain?(%AST.ArrayPattern{elements: elements}),
        do: Enum.any?(elements, &optional_chain?/1)

      defp optional_chain?(%AST.Property{value: value}), do: optional_chain?(value)
      defp optional_chain?(%AST.SpreadElement{argument: argument}), do: optional_chain?(argument)
      defp optional_chain?(_expression), do: false

      defp parse_conditional_tail(state, test, precedence) do
        {consequent, state} = parse_expression(state, 0)
        state = expect_value(state, ":")
        {alternate, state} = parse_expression(state, precedence)

        parse_binary_tail(
          state,
          %AST.ConditionalExpression{test: test, consequent: consequent, alternate: alternate},
          0
        )
      end

      defp parse_prefix(state) do
        token = current(state)

        cond do
          token.type in [:number, :string, :regexp, :boolean, :null] ->
            {%AST.Literal{value: token.value, raw: token.raw}, advance(state)}

          match_value?(state, "(") and arrow_after_parentheses?(state) ->
            {params, state} = parse_formal_parameters(state)
            state = expect_value(state, "=>")
            {body, state} = parse_arrow_body(state)
            state = Validation.validate_arrow_params(state, params, body)
            {%AST.ArrowFunctionExpression{params: params, body: body}, state}

          match_value?(state, "(") ->
            state = advance(state)
            {expr, state} = parse_expression(state, 0)
            {expr, expect_value(state, ")")}

          match_value?(state, "[") ->
            parse_array_expression(state)

          match_value?(state, "{") ->
            parse_object_expression(state)

          private_identifier_start?(token) ->
            parse_private_identifier_expression(state)

          prefix_update_operator?(token) ->
            state = advance(state)
            {argument, state} = parse_prefix(state)
            {argument, state} = parse_postfix_tail(state, argument)

            {%AST.UpdateExpression{operator: token.value, argument: argument, prefix: true},
             state}

          unary_operator?(token) ->
            operator = operator_value(token)
            state = advance(state)
            {argument, state} = parse_prefix(state)
            {argument, state} = parse_postfix_tail(state, argument)
            {%AST.UnaryExpression{operator: operator, argument: argument}, state}

          token.type == :template ->
            {parse_template_literal(token), advance(state)}

          async_arrow_start?(state) ->
            parse_async_arrow_expression(state)

          keyword?(state, "import") and peek_value(state) == "." and
              peek_value(state, 2) == "meta" ->
            parse_import_meta_expression(state)

          keyword?(state, "import") and peek_value(state) in ["(", "."] ->
            {%AST.Identifier{name: "import"}, advance(state)}

          keyword?(state, "new") and peek_value(state) == "." ->
            parse_new_target_expression(state)

          keyword?(state, "new") ->
            parse_new_expression(state)

          keyword?(state, "class") ->
            parse_class_expression(state)

          match_value?(state, "@") ->
            parse_decorated_class_expression(state)

          function_start?(state) ->
            parse_function_expression(state)

          token.value == "yield" and (state.yield_allowed? or state.source_type == :module) ->
            parse_yield_expression(state)

          token.value == "await" and (state.await_allowed? or state.source_type == :module) ->
            parse_await_expression(state)

          identifier_like?(token) and peek_value(state) == "=>" ->
            state = advance(state)
            state = advance(state)
            {body, state} = parse_arrow_body(state)
            params = [%AST.Identifier{name: token.value}]
            state = Validation.validate_arrow_params(state, params, body)

            {%AST.ArrowFunctionExpression{params: params, body: body}, state}

          identifier_like?(token) or token.value in ["this", "super"] ->
            {%AST.Identifier{name: token.value}, advance(state)}

          true ->
            {%AST.Literal{value: nil, raw: ""},
             add_error(state, token, "expected expression") |> recover_expression()}
        end
      end

      defp parse_decorated_class_expression(state) do
        state = skip_decorators(state)

        if keyword?(state, "class") do
          parse_class_expression(state)
        else
          {%AST.Literal{value: nil, raw: ""}, add_error(state, current(state), "expected class")}
        end
      end

      defp skip_decorators(state) do
        if match_value?(state, "@") do
          state |> advance() |> skip_decorator_tail(0) |> skip_decorators()
        else
          state
        end
      end

      defp skip_decorator_tail(state, 0) do
        cond do
          eof?(state) or match_value?(state, "@") or keyword?(state, "class") ->
            state

          match_value?(state, ["(", "[", "{"]) ->
            state |> advance() |> skip_decorator_tail(1)

          true ->
            state |> advance() |> skip_decorator_tail(0)
        end
      end

      defp skip_decorator_tail(state, depth) do
        cond do
          eof?(state) ->
            state

          match_value?(state, ["(", "[", "{"]) ->
            state |> advance() |> skip_decorator_tail(depth + 1)

          match_value?(state, [")", "]", "}"]) ->
            state |> advance() |> skip_decorator_tail(depth - 1)

          true ->
            state |> advance() |> skip_decorator_tail(depth)
        end
      end

      defp parse_template_literal(%Token{raw: raw}) do
        {quasis, expression_sources} = split_template_literal(raw)

        expressions =
          Enum.map(expression_sources, fn source ->
            case parse_expression_source(source) do
              {:ok, expression} -> expression
              :error -> %AST.Literal{value: nil, raw: ""}
            end
          end)

        %AST.TemplateLiteral{quasis: quasis, expressions: expressions}
      end

      defp split_template_literal(raw) do
        inner_size = max(byte_size(raw) - 2, 0)
        inner = if inner_size > 0, do: binary_part(raw, 1, inner_size), else: ""
        {segments, expressions} = split_template_inner(inner, 0, 0, [], [])

        quasis =
          Enum.with_index(
            segments,
            &%AST.TemplateElement{value: &1, raw: &1, tail: &2 == length(segments) - 1}
          )

        {quasis, expressions}
      end

      defp split_template_inner(raw, index, segment_start, segments, expressions) do
        cond do
          index >= byte_size(raw) ->
            segment = binary_part(raw, segment_start, byte_size(raw) - segment_start)
            {Enum.reverse([segment | segments]), Enum.reverse(expressions)}

          byte_at(raw, index) == ?\\ ->
            split_template_inner(raw, index + 2, segment_start, segments, expressions)

          byte_at(raw, index) == ?$ and byte_at(raw, index + 1) == ?{ ->
            segment = binary_part(raw, segment_start, index - segment_start)
            {expression, close_index} = read_template_expression(raw, index + 2, index + 2, 1)

            split_template_inner(raw, close_index + 1, close_index + 1, [segment | segments], [
              expression | expressions
            ])

          true ->
            split_template_inner(raw, index + 1, segment_start, segments, expressions)
        end
      end

      defp read_template_expression(raw, index, start, depth) do
        cond do
          index >= byte_size(raw) ->
            {binary_part(raw, start, byte_size(raw) - start), byte_size(raw)}

          byte_at(raw, index) in [?\", ?'] ->
            read_template_expression(
              raw,
              skip_quoted(raw, index, byte_at(raw, index)),
              start,
              depth
            )

          byte_at(raw, index) == ?` ->
            read_template_expression(raw, skip_nested_template(raw, index), start, depth)

          byte_at(raw, index) == ?{ ->
            read_template_expression(raw, index + 1, start, depth + 1)

          byte_at(raw, index) == ?} and depth == 1 ->
            {binary_part(raw, start, index - start), index}

          byte_at(raw, index) == ?} ->
            read_template_expression(raw, index + 1, start, depth - 1)

          true ->
            read_template_expression(raw, index + 1, start, depth)
        end
      end

      defp skip_quoted(raw, index, quote) do
        next_index = index + 1

        cond do
          next_index >= byte_size(raw) -> next_index
          byte_at(raw, next_index) == ?\\ -> skip_quoted(raw, next_index + 1, quote)
          byte_at(raw, next_index) == quote -> next_index + 1
          true -> skip_quoted(raw, next_index, quote)
        end
      end

      defp skip_nested_template(raw, index) do
        {_, close_index} = read_template_body(raw, index + 1)
        close_index + 1
      end

      defp read_template_body(raw, index) do
        cond do
          index >= byte_size(raw) ->
            {"", byte_size(raw)}

          byte_at(raw, index) == ?\\ ->
            read_template_body(raw, index + 2)

          byte_at(raw, index) == ?` ->
            {"", index}

          byte_at(raw, index) == ?$ and byte_at(raw, index + 1) == ?{ ->
            {_expression, close_index} = read_template_expression(raw, index + 2, index + 2, 1)
            read_template_body(raw, close_index + 1)

          true ->
            read_template_body(raw, index + 1)
        end
      end

      defp parse_expression_source(source) do
        with {:ok, tokens} <- Lexer.tokenize(source) do
          state = new_state(tokens)
          {expression, _state} = parse_expression(state, 0)
          {:ok, expression}
        else
          _ -> :error
        end
      end

      defp byte_at(raw, index) when index >= 0 and index < byte_size(raw),
        do: :binary.at(raw, index)

      defp byte_at(_raw, _index), do: nil

      defp parse_private_identifier_expression(state) do
        state = advance(state)
        token = current(state)

        if identifier_like?(token) do
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

      defp parse_async_arrow_expression(state) do
        state = advance(state)

        previous_await_allowed? = state.await_allowed?
        state = %{state | await_allowed?: true}

        {params, state} =
          if match_value?(state, "(") do
            parse_formal_parameters(state)
          else
            {param, state} = parse_binding_identifier(state)
            {[param], state}
          end

        state = %{state | await_allowed?: previous_await_allowed?}

        state = expect_value(state, "=>")
        {body, state} = parse_arrow_body(state, true)

        state =
          state
          |> Validation.validate_async_params(true, params)
          |> Validation.validate_arrow_params(params, body)

        {%AST.ArrowFunctionExpression{params: params, body: body, async: true}, state}
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
              match_value?(state, ",") -> parse_array_elements(advance(state), [element | acc])
              match_value?(state, "]") -> {Enum.reverse([element | acc]), advance(state)}
              true -> {Enum.reverse([element | acc]), expect_value(state, "]")}
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

          match_value?(state, ["get", "set"]) and accessor_key_start?(state) ->
            parse_accessor_property(state)

          true ->
            parse_regular_object_property(state)
        end
      end

      defp parse_generator_object_method(state) do
        state = advance(state)
        {key, computed?, state} = parse_property_key_with_computed(state)
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, true, false)

        state =
          state
          |> Validation.validate_generator_params(true, params)
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
          |> Validation.validate_async_params(true, params)
          |> Validation.validate_generator_params(generator?, params)
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
            {params, state} = parse_formal_parameters(state)
            {body, state} = parse_function_body(state, false, false)
            state = Validation.validate_strict_function_params(state, params, body)

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
            {%AST.Property{key: key, value: key, shorthand: true, computed: computed?}, state}

          true ->
            {%AST.Property{key: key, value: key, computed: computed?}, state}
        end
      end

      defp parse_accessor_property(state) do
        kind = current(state).value |> String.to_atom()
        state = advance(state)
        {key, computed?, state} = parse_property_key_with_computed(state)
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, false, false)
        state = Validation.validate_strict_function_params(state, params, body)

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

          true ->
            {%AST.Identifier{name: ""}, false, add_error(state, token, "expected property key")}
        end
      end

      defp property_function_name(%AST.Identifier{} = id), do: id
      defp property_function_name(_), do: nil

      defp parse_yield_expression(state) do
        state = advance(state)

        cond do
          eof?(state) or current(state).before_line_terminator? or statement_end?(state) or
              match_value?(state, [",", "]", ")"]) ->
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

      defp parse_function_body(state, generator?, async?) do
        previous_yield_allowed? = state.yield_allowed?
        previous_await_allowed? = state.await_allowed?

        {body, state} =
          parse_block_statement(%{state | yield_allowed?: generator?, await_allowed?: async?})

        {body,
         %{
           state
           | yield_allowed?: previous_yield_allowed?,
             await_allowed?: previous_await_allowed?
         }}
      end

      defp parse_arrow_body(state, async? \\ false) do
        previous_await_allowed? = state.await_allowed?
        state = %{state | await_allowed?: async?}

        {body, state} =
          if match_value?(state, "{") do
            parse_block_statement(state)
          else
            parse_expression(state, 2)
          end

        {body, %{state | await_allowed?: previous_await_allowed?}}
      end

      defp parse_arguments(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc), add_error(state, current(state), "unterminated argument list")}

          match_value?(state, ")") ->
            {Enum.reverse(acc), advance(state)}

          match_value?(state, "...") ->
            state = advance(state)
            {argument, state} = parse_expression(state, 2)
            arg = %AST.SpreadElement{argument: argument}

            cond do
              match_value?(state, ",") -> parse_arguments(advance(state), [arg | acc])
              match_value?(state, ")") -> {Enum.reverse([arg | acc]), advance(state)}
              true -> {Enum.reverse([arg | acc]), expect_value(state, ")")}
            end

          true ->
            {arg, state} = parse_expression(state, 2)

            cond do
              match_value?(state, ",") -> parse_arguments(advance(state), [arg | acc])
              match_value?(state, ")") -> {Enum.reverse([arg | acc]), advance(state)}
              true -> {Enum.reverse([arg | acc]), expect_value(state, ")")}
            end
        end
      end

      defp parse_property_identifier(state) do
        token = current(state)

        cond do
          match_value?(state, "#") ->
            state = advance(state)
            token = current(state)

            if identifier_like?(token) do
              {%AST.PrivateIdentifier{name: token.value}, advance(state)}
            else
              {%AST.PrivateIdentifier{name: ""}, add_error(state, token, "expected private name")}
            end

          token.type in [:identifier, :keyword, :boolean, :null] ->
            {%AST.Identifier{name: to_string(token.value)}, advance(state)}

          true ->
            {%AST.Identifier{name: ""}, add_error(state, token, "expected property name")}
        end
      end

      defp binary_node(",", %AST.SequenceExpression{expressions: expressions}, right) do
        %AST.SequenceExpression{expressions: expressions ++ [right]}
      end

      defp binary_node(",", left, right) do
        %AST.SequenceExpression{expressions: [left, right]}
      end

      defp binary_node(operator, left, right) when operator in @assignment_ops do
        %AST.AssignmentExpression{
          operator: operator,
          left: assignment_target_pattern(left),
          right: right
        }
      end

      defp binary_node(operator, left, right) when operator in @logical_ops do
        %AST.LogicalExpression{operator: operator, left: left, right: right}
      end

      defp binary_node(operator, left, right) do
        %AST.BinaryExpression{operator: operator, left: left, right: right}
      end

      defp assignment_target_pattern(%AST.ObjectExpression{properties: properties}) do
        %AST.ObjectPattern{properties: Enum.map(properties, &assignment_target_pattern/1)}
      end

      defp assignment_target_pattern(%AST.ArrayExpression{elements: elements}) do
        %AST.ArrayPattern{elements: Enum.map(elements, &assignment_target_pattern/1)}
      end

      defp assignment_target_pattern(%AST.Property{} = property) do
        %AST.Property{property | value: assignment_target_pattern(property.value)}
      end

      defp assignment_target_pattern(%AST.SpreadElement{argument: argument}) do
        %AST.RestElement{argument: assignment_target_pattern(argument)}
      end

      defp assignment_target_pattern(%AST.AssignmentExpression{
             operator: "=",
             left: left,
             right: right
           }) do
        %AST.AssignmentPattern{left: assignment_target_pattern(left), right: right}
      end

      defp assignment_target_pattern(%AST.AssignmentPattern{left: left} = pattern) do
        %AST.AssignmentPattern{pattern | left: assignment_target_pattern(left)}
      end

      defp assignment_target_pattern(target), do: target

      defp parse_parenthesized_expression(state) do
        state = expect_value(state, "(")
        {expr, state} = parse_expression(state, 0)
        {expr, expect_value(state, ")")}
      end

      defp parse_formal_parameters(state) do
        state = expect_value(state, "(")
        parse_parameter_list(state, [])
      end

      defp parse_parameter_list(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc), add_error(state, current(state), "unterminated parameter list")}

          match_value?(state, ")") ->
            {Enum.reverse(acc), advance(state)}

          match_value?(state, "...") ->
            state = advance(state)
            {argument, state} = parse_binding_pattern(state)
            state = validate_rest_initializer(state)
            param = %AST.RestElement{argument: argument}
            state = expect_value(state, ")")
            {Enum.reverse([param | acc]), state}

          true ->
            {param, state} = parse_binding_pattern(state)

            {param, state} =
              if match_value?(state, "=") do
                state = advance(state)
                {right, state} = parse_expression(state, 2)
                {%AST.AssignmentPattern{left: param, right: right}, state}
              else
                {param, state}
              end

            cond do
              match_value?(state, ",") -> parse_parameter_list(advance(state), [param | acc])
              match_value?(state, ")") -> {Enum.reverse([param | acc]), advance(state)}
              true -> {Enum.reverse([param | acc]), expect_value(state, ")")}
            end
        end
      end
    end
  end
end
