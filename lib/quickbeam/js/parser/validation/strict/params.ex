defmodule QuickBEAM.JS.Parser.Validation.Strict.Params do
  @moduledoc "Async, generator, and duplicate parameter validation."

  alias QuickBEAM.JS.Parser.AST
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]
  import QuickBEAM.JS.Parser.Validation.Strict.Helpers

  def validate_async_body_bindings(state, true, %AST.BlockStatement{body: body}) do
    if body_contains_name?(body, "await") do
      add_error(state, current(state), "await parameter not allowed in async function")
    else
      state
    end
  end

  def validate_async_body_bindings(state, _async?, _body), do: state

  def validate_async_function_name(state, _async?, _id), do: state

  def validate_async_generator_function_name(state, true, %AST.Identifier{name: "await"}) do
    add_error(state, current(state), "await parameter not allowed in async function")
  end

  def validate_async_generator_function_name(state, _async_generator?, _id), do: state

  def validate_async_params(state, true, params) do
    names = identifier_param_names(params)

    if Enum.any?(names, &(&1 == "await")) or Enum.any?(params, &contains_await_identifier?/1) or
         Enum.any?(params, &contains_await_expression?/1) do
      add_error(state, current(state), "await parameter not allowed in async function")
    else
      state
    end
  end

  def validate_async_params(state, _async?, _params), do: state

  def validate_generator_body_bindings(state, true, %AST.BlockStatement{body: body}) do
    cond do
      body_contains_name?(body, "yield") ->
        add_error(state, current(state), "yield parameter not allowed in generator function")

      Enum.any?(body, &yield_in_no_in_statement?/1) ->
        add_error(state, current(state), "yield expression not allowed here")

      Enum.any?(body, &nested_yield_statement?/1) ->
        add_error(state, current(state), "yield expression not allowed here")

      true ->
        state
    end
  end

  def validate_generator_body_bindings(state, _generator?, _body), do: state

  defp yield_in_no_in_statement?(%AST.ForStatement{init: init}),
    do: yield_in_no_in_expression?(init)

  defp yield_in_no_in_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &yield_in_no_in_statement?/1)

  defp yield_in_no_in_statement?(_statement), do: false

  defp yield_in_no_in_expression?(%AST.YieldExpression{argument: argument}),
    do: yield_argument_contains_in?(argument)

  defp yield_in_no_in_expression?(_expression), do: false

  defp yield_argument_contains_in?(%AST.BinaryExpression{operator: "in"}), do: true

  defp yield_argument_contains_in?(%AST.BinaryExpression{left: left, right: right}),
    do: yield_argument_contains_in?(left) or yield_argument_contains_in?(right)

  defp yield_argument_contains_in?(_expression), do: false

  defp nested_yield_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &nested_yield_statement?/1)

  defp nested_yield_statement?(%AST.ExpressionStatement{expression: expression}),
    do: nested_yield_expression?(expression)

  defp nested_yield_statement?(%AST.ReturnStatement{argument: argument}),
    do: nested_yield_expression?(argument)

  defp nested_yield_statement?(%AST.VariableDeclaration{declarations: declarations}) do
    Enum.any?(declarations, &nested_yield_expression?(&1.init))
  end

  defp nested_yield_statement?(_statement), do: false

  defp nested_yield_expression?(%AST.YieldExpression{parenthesized?: true}), do: false
  defp nested_yield_expression?(%AST.YieldExpression{argument: %AST.YieldExpression{}}), do: false

  defp nested_yield_expression?(%AST.YieldExpression{argument: argument}),
    do: contains_unparenthesized_yield_expression?(argument)

  defp nested_yield_expression?(%AST.BinaryExpression{left: left, right: right}),
    do: nested_yield_expression?(left) or nested_yield_expression?(right)

  defp nested_yield_expression?(%AST.SequenceExpression{expressions: expressions}),
    do: Enum.any?(expressions, &nested_yield_expression?/1)

  defp nested_yield_expression?(_expression), do: false

  defp contains_unparenthesized_yield_expression?(%AST.YieldExpression{parenthesized?: true}),
    do: false

  defp contains_unparenthesized_yield_expression?(%AST.YieldExpression{}), do: true

  defp contains_unparenthesized_yield_expression?(%AST.BinaryExpression{
         left: left,
         right: right
       }),
       do:
         contains_unparenthesized_yield_expression?(left) or
           contains_unparenthesized_yield_expression?(right)

  defp contains_unparenthesized_yield_expression?(%AST.SequenceExpression{
         expressions: expressions
       }),
       do: Enum.any?(expressions, &contains_unparenthesized_yield_expression?/1)

  defp contains_unparenthesized_yield_expression?(_expression), do: false

  def validate_generator_function_name(state, true, %AST.Identifier{name: "yield"}) do
    add_error(state, current(state), "yield parameter not allowed in generator function")
  end

  def validate_generator_function_name(state, _generator?, _id), do: state

  def validate_generator_params(state, true, params) do
    cond do
      Enum.any?(identifier_param_names(params), &(&1 == "yield")) ->
        add_error(state, current(state), "yield parameter not allowed in generator function")

      Enum.any?(params, &contains_yield_expression?/1) ->
        add_error(state, current(state), "yield parameter not allowed in generator function")

      true ->
        state
    end
  end

  def validate_generator_params(state, _generator?, _params), do: state

  def validate_unique_params(state, params) do
    if duplicate_param_names?(params) do
      add_error(state, current(state), "duplicate parameter name not allowed in strict mode")
    else
      state
    end
  end
end
