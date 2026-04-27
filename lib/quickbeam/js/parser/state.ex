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

      defp consume_async_modifier(state) do
        if keyword?(state, "async") and peek_value(state) == "function" do
          {true, advance(state)}
        else
          {false, state}
        end
      end

      defp consume_generator_marker(state) do
        if match_value?(state, "*"), do: {true, advance(state)}, else: {false, state}
      end

      defp function_start?(state) do
        keyword?(state, "function") or
          (keyword?(state, "async") and peek_value(state) == "function")
      end

      defp label_start?(state), do: identifier_like?(current(state)) and peek_value(state) == ":"

      defp accessor_key_start?(state) do
        (peek(state).type in [:identifier, :keyword] and peek_value(state, 2) == "(") or
          (peek(state).type in [:string, :number] and peek_value(state, 2) == "(") or
          (peek_value(state) == "#" and identifier_like?(peek(state, 2)) and
             peek_value(state, 3) == "(") or peek_value(state) == "["
      end

      defp async_method_start?(state) do
        match_value?(state, "async") and not peek(state).before_line_terminator? and
          ((identifier_like?(peek(state)) and peek_value(state, 2) == "(") or
             (peek(state).type in [:string, :number] and peek_value(state, 2) == "(") or
             (peek_value(state) == "#" and identifier_like?(peek(state, 2)) and
                peek_value(state, 3) == "(") or
             (peek_value(state) == "*" and identifier_like?(peek(state, 2)) and
                peek_value(state, 3) == "(") or
             (peek_value(state) == "*" and peek(state, 2).type in [:string, :number] and
                peek_value(state, 3) == "(") or
             (peek_value(state) == "*" and peek_value(state, 2) == "#" and
                identifier_like?(peek(state, 3)) and peek_value(state, 4) == "(") or
             peek_value(state) == "[")
      end

      defp async_arrow_start?(state) do
        keyword?(state, "async") and not peek(state).before_line_terminator? and
          ((identifier_like?(peek(state)) and peek_value(state, 2) == "=>") or
             (peek_value(state) == "(" and arrow_after_parentheses?(advance(state))))
      end

      defp arrow_after_parentheses?(state) do
        find_matching_paren(state, state.index, 0) == "=>"
      end

      defp find_matching_paren(%{token_count: token_count}, index, _depth)
           when index >= token_count,
           do: nil

      defp find_matching_paren(state, index, depth) do
        case token_at(state, index) do
          %Token{value: "("} ->
            find_matching_paren(state, index + 1, depth + 1)

          %Token{value: ")"} when depth == 1 ->
            token_at(state, index + 1).value

          %Token{value: ")"} ->
            find_matching_paren(state, index + 1, depth - 1)

          _ ->
            find_matching_paren(state, index + 1, depth)
        end
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

      defp consume_keyword_value(state), do: {current(state).value, advance(state)}

      defp keyword?(state, keyword),
        do: current(state).type == :keyword and current(state).value == keyword

      defp identifier_like?(%Token{type: :identifier}), do: true

      defp identifier_like?(%Token{type: :keyword, value: value}) do
        value in [
          "async",
          "get",
          "set",
          "of",
          "await",
          "yield",
          "implements",
          "interface",
          "package",
          "private",
          "protected",
          "public"
        ]
      end

      defp identifier_like?(_), do: false

      defp match_value?(state, values) when is_list(values), do: current(state).value in values
      defp match_value?(state, value), do: current(state).value == value

      defp operator_value(%Token{type: :keyword, value: value})
           when value in ["in", "instanceof", "typeof", "void", "delete"], do: value

      defp operator_value(%Token{value: value}), do: value

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
