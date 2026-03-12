defmodule Pegasus.Ast do
  @moduledoc false
  import NimbleParsec

  @enforce_keys [:name]

  defstruct @enforce_keys ++ [:extract, start_pos?: false, parsec: empty()]

  @dummy_context %{parsec: empty()}

  def to_nimble_parsec({:ok, list, "", _, _, _}, opts) do
    to_nimble_parsec(list, opts)
  end

  def to_nimble_parsec(ast, opts) when is_list(ast) do
    Enum.map(ast, &to_nimble_parsec(&1, opts))
  end

  def to_nimble_parsec({name, parser_ast}, opts) do
    name_opts = Keyword.get(opts, name, [])

    %__MODULE__{name: name}
    |> maybe_add_position(name_opts)
    |> translate_sequence(parser_ast)
    |> maybe_extract()
    |> maybe_collect(name_opts)
    |> maybe_token(name, name_opts)
    |> maybe_tag(name, name_opts)
    |> maybe_post_traverse(name_opts)
    |> maybe_ignore(name_opts)
    |> maybe_alias(name_opts)
  end

  defp maybe_add_position(context, name_opts) do
    if Keyword.get(name_opts, :start_position) do
      parsec = post_traverse(context.parsec, traversal_name(context.name, :start_pos))
      %{context | parsec: parsec, start_pos?: true}
    else
      context
    end
  end

  defp maybe_extract(context) do
    if context.extract == :extract do
      %{context | parsec: post_traverse(context.parsec, traversal_name(context.name, :extract))}
    else
      context
    end
  end

  defp maybe_collect(context, name_opts) do
    if Keyword.get(name_opts, :collect) do
      %{context | parsec: reduce(context.parsec, {IO, :iodata_to_binary, []})}
    else
      context
    end
  end

  defp maybe_token(context = %{parsec: parsec}, name, name_opts) do
    case Keyword.get(name_opts, :token, false) do
      false ->
        context

      true ->
        %{
          context
          | parsec: parsec |> tag(name) |> post_traverse(traversal_name(name, :tag)),
            extract: :tag
        }

      token ->
        %{
          context
          | parsec: parsec |> tag(token) |> post_traverse(traversal_name(name, :tag)),
            extract: :tag
        }
    end
  end

  defp maybe_tag(context = %{parsec: parsec}, name, name_opts) do
    case Keyword.get(name_opts, :tag, false) do
      false -> context
      true -> %{context | parsec: tag(parsec, name)}
      tag -> %{context | parsec: tag(parsec, tag)}
    end
  end

  defp maybe_post_traverse(context, name_opts) do
    if post_traverse = Keyword.get(name_opts, :post_traverse) do
      %{context | parsec: post_traverse(context.parsec, post_traverse)}
    else
      context
    end
  end

  defp maybe_ignore(context, name_opts) do
    if Keyword.get(name_opts, :ignore) do
      %{context | parsec: ignore(context.parsec)}
    else
      context
    end
  end

  defp maybe_alias(context, name_opts) do
    if substitution = Keyword.get(name_opts, :alias) do
      %{context | parsec: parsec(substitution)}
    else
      context
    end
  end

  def translate_sequence(context, ast) do
    Enum.reduce(ast, context, &translate/2)
  end

  defp translate(:dot, context) do
    %{context | parsec: utf8_char(context.parsec, not: 0)}
  end

  defp translate({:char, ranges}, context) do
    %{context | parsec: ascii_char(context.parsec, ranges)}
  end

  defp translate({:literal, literal}, context) do
    %{context | parsec: string(context.parsec, literal)}
  end

  defp translate({:lookahead, content}, context) do
    %{parsec: lookahead} = translate(content, @dummy_context)
    %{context | parsec: lookahead(context.parsec, lookahead)}
  end

  defp translate({:lookahead_not, content}, context) do
    %{parsec: lookahead_not} = translate(content, @dummy_context)
    %{context | parsec: lookahead_not(context.parsec, lookahead_not)}
  end

  defp translate({:optional, content}, context) do
    %{parsec: optional} = translate(content, @dummy_context)
    %{context | parsec: optional(context.parsec, optional)}
  end

  defp translate({:repeat, content}, context) do
    %{parsec: repeated} = translate(content, @dummy_context)
    %{context | parsec: repeat(context.parsec, repeated)}
  end

  defp translate({:times, content}, context) do
    %{parsec: repeated} = translate(content, @dummy_context)
    %{context | parsec: times(context.parsec, repeated, min: 1)}
  end

  defp translate({:identifier, identifier}, context) do
    %{context | parsec: parsec(context.parsec, identifier)}
  end

  defp translate({:choice, list_of_choices}, context) do
    choices = Enum.map(list_of_choices, &translate_sequence(@dummy_context, &1).parsec)
    %{context | parsec: choice(context.parsec, choices)}
  end

  defp translate({:ungroup, commands}, context) do
    grouped = translate_sequence(@dummy_context, commands)
    %{context | parsec: concat(context.parsec, grouped.parsec)}
  end

  defp translate({:extract, commands}, context) do
    grouped = translate_sequence(@dummy_context, commands)
    tagged = tag(grouped.parsec, :__extract__)
    %{context | parsec: concat(context.parsec, tagged), extract: :extract}
  end

  def traversal_name(name, tag), do: :"#{name}-#{tag}"

  defmacro traversals(ast) do
    quote bind_quoted: [ast: ast] do
      if ast.start_pos? do
        start_pos_name = Pegasus.Ast.traversal_name(ast.name, :start_pos)

        defp(unquote(start_pos_name)(rest, args, context, {line, offset}, col)) do
          {rest, [%{line: line, column: col - offset + 1, offset: offset} | args], context}
        end
      end

      case ast.extract do
        :tag ->
          extract_name = Pegasus.Ast.traversal_name(ast.name, :tag)

          defp(unquote(extract_name)(rest, [{tag, _} | args_rest], context, _, _)) do
            {rest, [tag | args_rest], context}
          end

        :extract ->
          extract_name = Pegasus.Ast.traversal_name(ast.name, :extract)

          defp unquote(extract_name)(rest, args, context, _, _) do
            extracted =
              Enum.flat_map(args, fn
                {:__extract__, what} ->
                  what
                  |> Enum.filter(&(is_binary(&1) or &1 in 1..0x10FFFF))
                  |> IO.iodata_to_binary()
                  |> List.wrap()

                _ ->
                  []
              end)

            {rest, extracted, context}
          end

        _ ->
          []
      end
    end
  end
end
