defmodule QuickBEAM.JS.Parser.Expressions.Core do
  @moduledoc "Core Pratt expression grammar."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Lexer, Token, Validation}

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
    end
  end
end
