defmodule QuickBEAM.JS.Parser.Validation.Targets do
  @moduledoc "Assignment/update target and class constructor validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  @assignment_ops ~w[= += -= *= /= %= **= <<= >>= >>>= &= ^= |= &&= ||= ??=]

  def validate_duplicate_constructors(state, body) do
    constructors = Enum.count(body, &match?(%AST.MethodDefinition{kind: :constructor}, &1))

    if constructors > 1 do
      add_error(state, current(state), "duplicate constructor")
    else
      state
    end
  end

  def validate_optional_chain_base(state, %AST.Identifier{name: "super"}) do
    add_error(state, current(state), "optional chain not allowed on super")
  end

  def validate_optional_chain_base(state, _left), do: state

  def validate_assignment_target(state, operator, left) when operator in @assignment_ops do
    cond do
      optional_chain?(left) ->
        add_error(state, current(state), "optional chain is not a valid assignment target")

      not valid_assignment_target?(operator, left) ->
        add_error(state, current(state), "invalid assignment target")

      true ->
        state
    end
  end

  def validate_assignment_target(state, _operator, _left), do: state

  def validate_update_target(state, argument) do
    cond do
      optional_chain?(argument) ->
        add_error(state, current(state), "optional chain is not a valid assignment target")

      not valid_update_target?(argument) ->
        add_error(state, current(state), "invalid assignment target")

      true ->
        state
    end
  end

  defp valid_assignment_target?(_operator, %AST.Identifier{}), do: true
  defp valid_assignment_target?(_operator, %AST.MemberExpression{}), do: true
  defp valid_assignment_target?(_operator, %AST.CallExpression{}), do: true
  defp valid_assignment_target?("=", %AST.ObjectExpression{}), do: true
  defp valid_assignment_target?("=", %AST.ArrayExpression{}), do: true
  defp valid_assignment_target?("=", %AST.ObjectPattern{}), do: true
  defp valid_assignment_target?("=", %AST.ArrayPattern{}), do: true
  defp valid_assignment_target?(_operator, _target), do: false

  defp valid_update_target?(%AST.Identifier{}), do: true
  defp valid_update_target?(%AST.MemberExpression{}), do: true
  defp valid_update_target?(%AST.CallExpression{}), do: true
  defp valid_update_target?(_target), do: false

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

  defp current(state), do: token_at(state, state.index)

  defp token_at(%{token_count: token_count, last_token: last_token}, index)
       when index >= token_count,
       do: last_token

  defp token_at(%{tokens: tokens}, index), do: elem(tokens, index)

  defp add_error(state, %Token{} = token, message) do
    error = %Error{
      message: message,
      line: token.line,
      column: token.column,
      offset: token.start
    }

    %{state | errors: [error | state.errors]}
  end
end
