defmodule QuickBEAM.JS.Parser.Expressions.Templates do
  @moduledoc "Template literal parsing helpers."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Lexer, Token, Validation}

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
    end
  end
end
