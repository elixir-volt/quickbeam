defmodule QuickBEAM.JS.Parser.Predicates do
  @moduledoc "Shared token and grammar predicates for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.Token

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
          (peek(state).type in [:string, :number, :boolean, :null] and
             peek_value(state, 2) == "(") or
          (peek_value(state) == "#" and identifier_like?(peek(state, 2)) and
             peek_value(state, 3) == "(") or peek_value(state) == "["
      end

      defp async_method_start?(state) do
        match_value?(state, "async") and not peek(state).before_line_terminator? and
          ((identifier_like?(peek(state)) and peek_value(state, 2) == "(") or
             (peek(state).type in [:string, :number, :boolean, :null] and
                peek_value(state, 2) == "(") or
             (peek_value(state) == "#" and identifier_like?(peek(state, 2)) and
                peek_value(state, 3) == "(") or
             (peek_value(state) == "*" and identifier_like?(peek(state, 2)) and
                peek_value(state, 3) == "(") or
             (peek_value(state) == "*" and
                peek(state, 2).type in [:string, :number, :boolean, :null] and
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
    end
  end
end
