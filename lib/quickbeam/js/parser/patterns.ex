defmodule QuickBEAM.JS.Parser.Patterns do
  @moduledoc "Binding and destructuring pattern grammar for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp parse_binding_pattern(state) do
        cond do
          match_value?(state, "[") -> parse_array_pattern(state)
          match_value?(state, "{") -> parse_object_pattern(state)
          true -> parse_binding_identifier(state)
        end
      end

      defp parse_binding_identifier(state) do
        token = current(state)

        cond do
          state.source_type == :module and token.type == :keyword and token.value == "await" ->
            {%AST.Identifier{name: ""},
             add_error(state, token, "expected binding identifier") |> recover_expression()}

          identifier_like?(token) ->
            {%AST.Identifier{name: token.value}, advance(state)}

          true ->
            {%AST.Identifier{name: ""},
             add_error(state, token, "expected binding identifier") |> recover_expression()}
        end
      end

      defp parse_array_pattern(state) do
        state = advance(state)
        {elements, state} = parse_array_pattern_elements(state, [])
        {%AST.ArrayPattern{elements: elements}, state}
      end

      defp parse_object_pattern(state) do
        state = advance(state)
        {properties, state} = parse_object_pattern_properties(state, [])
        {%AST.ObjectPattern{properties: properties}, state}
      end

      defp parse_object_pattern_properties(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc),
             add_error(state, current(state), "unterminated object binding pattern")}

          match_value?(state, "}") ->
            {Enum.reverse(acc), advance(state)}

          match_value?(state, "...") ->
            state = advance(state)
            {argument, state} = parse_binding_pattern(state)
            state = validate_rest_initializer(state)
            rest = %AST.RestElement{argument: argument}

            cond do
              match_value?(state, ",") ->
                state = add_error(state, current(state), "rest element must be last")
                parse_object_pattern_properties(advance(state), [rest | acc])

              match_value?(state, "}") ->
                {Enum.reverse([rest | acc]), advance(state)}

              true ->
                {Enum.reverse([rest | acc]), expect_value(state, "}")}
            end

          true ->
            {key, computed?, state} = parse_property_key_with_computed(state)

            {value, state} =
              cond do
                match_value?(state, ":") ->
                  state = advance(state)
                  parse_binding_pattern(state)

                match?(%AST.Identifier{}, key) ->
                  {key, state}

                true ->
                  {key, state}
              end

            {value, state} =
              if match_value?(state, "=") do
                state = advance(state)
                {right, state} = parse_expression(state, 2)
                {%AST.AssignmentPattern{left: value, right: right}, state}
              else
                {value, state}
              end

            property = %AST.Property{
              key: key,
              value: value,
              shorthand: key == value,
              computed: computed?
            }

            cond do
              match_value?(state, ",") ->
                parse_object_pattern_properties(advance(state), [property | acc])

              match_value?(state, "}") ->
                {Enum.reverse([property | acc]), advance(state)}

              true ->
                {Enum.reverse([property | acc]), expect_value(state, "}")}
            end
        end
      end

      defp parse_array_pattern_elements(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc),
             add_error(state, current(state), "unterminated array binding pattern")}

          match_value?(state, "]") ->
            {Enum.reverse(acc), advance(state)}

          match_value?(state, ",") ->
            parse_array_pattern_elements(advance(state), [nil | acc])

          match_value?(state, "...") ->
            state = advance(state)
            {argument, state} = parse_binding_pattern(state)
            state = validate_rest_initializer(state)
            rest = %AST.RestElement{argument: argument}

            cond do
              match_value?(state, ",") ->
                state = add_error(state, current(state), "rest element must be last")
                parse_array_pattern_elements(advance(state), [rest | acc])

              match_value?(state, "]") ->
                {Enum.reverse([rest | acc]), advance(state)}

              true ->
                {Enum.reverse([rest | acc]), expect_value(state, "]")}
            end

          true ->
            {element, state} = parse_binding_pattern(state)

            {element, state} =
              if match_value?(state, "=") do
                state = advance(state)
                {right, state} = parse_expression(state, 2)
                {%AST.AssignmentPattern{left: element, right: right}, state}
              else
                {element, state}
              end

            cond do
              match_value?(state, ",") ->
                parse_array_pattern_elements(advance(state), [element | acc])

              match_value?(state, "]") ->
                {Enum.reverse([element | acc]), advance(state)}

              true ->
                {Enum.reverse([element | acc]), expect_value(state, "]")}
            end
        end
      end
    end
  end
end
