defmodule QuickBEAM.JS.Parser.Validation.Helpers do
  @moduledoc false

  alias QuickBEAM.JS.Parser.{Error, Token}

  def current(state), do: token_at(state, state.index)

  def token_at(%{token_count: token_count, last_token: last_token}, index)
      when index >= token_count,
      do: last_token

  def token_at(%{tokens: tokens}, index), do: elem(tokens, index)

  def add_error(state, %Token{} = token, message) do
    error = %Error{
      message: message,
      line: token.line,
      column: token.column,
      offset: token.start
    }

    %{state | errors: [error | state.errors]}
  end
end
