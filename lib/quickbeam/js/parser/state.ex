defmodule QuickBEAM.JS.Parser.State do
  @moduledoc "Shared parser-state and token cursor helpers."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp new_state(tokens, opts \\ []) do
        token_tuple = List.to_tuple(tokens)
        token_count = tuple_size(token_tuple)

        %__MODULE__{
          tokens: token_tuple,
          token_count: token_count,
          last_token: if(token_count > 0, do: elem(token_tuple, token_count - 1)),
          source_type: Keyword.get(opts, :source_type, :script),
          errors: Keyword.get(opts, :errors, [])
        }
      end

      defp consume_semicolon(state) do
        cond do
          match_value?(state, ";") -> advance(state)
          eof?(state) -> state
          current(state).before_line_terminator? -> state
          true -> state
        end
      end

      defp statement_end?(state), do: match_value?(state, [";", "}"])

      defp expect_value(state, value) do
        if match_value?(state, value),
          do: advance(state),
          else: add_error(state, current(state), "expected #{value}")
      end

      defp expect_keyword(state, keyword) do
        if keyword?(state, keyword),
          do: advance(state),
          else: add_error(state, current(state), "expected #{keyword}")
      end

      defp expect_identifier_value(state, value) do
        if identifier_like?(current(state)) and current(state).value == value,
          do: advance(state),
          else: add_error(state, current(state), "expected #{value}")
      end

      defp recover_expression(state) do
        if eof?(state) or statement_end?(state) or match_value?(state, ",") do
          state
        else
          state |> advance() |> recover_expression()
        end
      end

      defp current(%__MODULE__{} = state), do: token_at(state, state.index)

      defp peek(%__MODULE__{} = state, offset \\ 1), do: token_at(state, state.index + offset)

      defp token_at(%{token_count: token_count, last_token: last_token}, index)
           when index >= token_count,
           do: last_token

      defp token_at(%{tokens: tokens}, index), do: elem(tokens, index)

      defp peek_value(state, offset \\ 1) do
        case peek(state, offset) do
          nil -> nil
          token -> token.value
        end
      end

      defp advance(%__MODULE__{} = state),
        do: %{state | index: min(state.index + 1, state.token_count - 1)}

      defp eof?(state), do: current(state).type == :eof

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
  end
end
