defmodule QuickBEAM.JS.Parser.Expressions.Functions do
  @moduledoc "Function expression, arrow body, arguments, and parameter grammar."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Lexer, Token, Validation}

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

        {params, state} = parse_function_formal_parameters(state, generator?, async?)
        {body, state} = parse_function_body(state, generator?, async?)

        state =
          state
          |> Validation.validate_super_params(params)
          |> Validation.validate_async_function_name(async?, id)
          |> Validation.validate_async_generator_function_name(async? and generator?, id)
          |> Validation.validate_async_params(async?, params)
          |> Validation.validate_async_body_bindings(async?, body)
          |> Validation.validate_generator_function_name(generator?, id)
          |> Validation.validate_generator_params(generator?, params)
          |> Validation.validate_generator_body_bindings(generator?, body)
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
          |> Validation.validate_super_params(params)
          |> Validation.validate_async_params(true, params)
          |> Validation.validate_async_body_bindings(true, body)
          |> Validation.validate_arrow_params(params, body)

        {%AST.ArrowFunctionExpression{params: params, body: body, async: true}, state}
      end

      defp parse_function_formal_parameters(state, yield_allowed?, await_allowed?) do
        previous_yield_allowed? = state.yield_allowed?
        previous_await_allowed? = state.await_allowed?

        {params, state} =
          parse_formal_parameters(%{
            state
            | yield_allowed?: yield_allowed?,
              await_allowed?: await_allowed?
          })

        {params,
         %{
           state
           | yield_allowed?: previous_yield_allowed?,
             await_allowed?: previous_await_allowed?
         }}
      end

      defp parse_function_body(state, generator?, async?) do
        previous_yield_allowed? = state.yield_allowed?
        previous_await_allowed? = state.await_allowed?

        {body, state} =
          parse_function_block_statement(%{
            state
            | yield_allowed?: generator?,
              await_allowed?: async?
          })

        {body,
         %{
           state
           | yield_allowed?: previous_yield_allowed?,
             await_allowed?: previous_await_allowed?
         }}
      end

      defp parse_function_block_statement(state) do
        state = expect_value(state, "{")
        {body, state} = parse_statement_list(state, [])
        state = Validation.validate_duplicate_lexical_bindings(state, body)
        {%AST.BlockStatement{body: body}, expect_value(state, "}")}
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

            continue_arguments(state, arg, acc)

          true ->
            {arg, state} = parse_expression(state, 2)

            continue_arguments(state, arg, acc)
        end
      end

      defp continue_arguments(state, arg, acc) do
        cond do
          match_value?(state, ",") -> parse_arguments(advance(state), [arg | acc])
          match_value?(state, ")") -> {Enum.reverse([arg | acc]), advance(state)}
          true -> {Enum.reverse([arg | acc]), expect_value(state, ")")}
        end
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

            {param, state} = maybe_assignment_pattern(state, param)

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
