defmodule QuickBEAM.JS.Parser.Lexer do
  @moduledoc "Hand-written JavaScript lexer used by the experimental QuickBEAM parser."

  alias QuickBEAM.JS.Parser.{Error, Token}

  defstruct source: "",
            offset: 0,
            line: 1,
            column: 0,
            length: 0,
            token_start_line: 1,
            token_start_column: 0,
            pending_line_terminator?: false,
            last_token: nil,
            errors: []

  @type t :: %__MODULE__{}

  @keywords MapSet.new(~w[
    break case catch class const continue debugger default delete do else export extends
    finally for function if import in instanceof let new return super switch this throw try
    typeof var void while with yield async await of static get set implements interface package private protected public
  ])

  @identifier_like_keywords MapSet.new(~w[
    async get set of implements interface package private protected public
  ])

  @doc "Creates a lexer state for a source string."
  def new(source) when is_binary(source) do
    %__MODULE__{source: source, length: byte_size(source)}
  end

  @doc "Tokenizes a source string."
  def tokenize(source) when is_binary(source) do
    source
    |> new()
    |> collect([])
  end

  @doc "Returns the next token and updated lexer state."
  def next(%__MODULE__{} = lexer) do
    lexer = skip_trivia(lexer)

    lexer = %{lexer | token_start_line: lexer.line, token_start_column: lexer.column}

    if eof?(lexer) do
      token(lexer, :eof, :eof, "", lexer.offset)
    else
      scan_token(lexer)
    end
  end

  defp collect(lexer, acc) do
    {token, lexer} = next(lexer)
    acc = [token | acc]

    if token.type == :eof do
      tokens = Enum.reverse(acc)

      case lexer.errors do
        [] -> {:ok, tokens}
        errors -> {:error, tokens, Enum.reverse(errors)}
      end
    else
      collect(lexer, acc)
    end
  end

  defp scan_token(lexer) do
    ch = current(lexer)

    cond do
      ch in [?", ?'] -> scan_string(lexer, ch)
      ch == ?` -> scan_template(lexer)
      ch in ?0..?9 -> scan_number(lexer)
      ch == ?. -> scan_dot_or_number(lexer)
      ch == ?/ and regexp_allowed?(lexer) -> scan_regexp(lexer)
      ch == ?\\ and peek(lexer, 1) == ?u -> scan_identifier(lexer)
      identifier_start?(ch) -> scan_identifier(lexer)
      true -> scan_punctuator(lexer)
    end
  end

  defp scan_dot_or_number(lexer) do
    case peek(lexer, 1) do
      ch when ch in ?0..?9 -> scan_number(lexer)
      _ -> scan_punctuator(lexer)
    end
  end

  defp scan_identifier(lexer) do
    start = lexer.offset

    {lexer, value} =
      if current(lexer) == ?\\ do
        {lexer, parts} = scan_identifier_parts(lexer, [])
        {lexer, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      else
        {lexer, escaped?} = advance_identifier_raw(lexer)
        raw = slice(lexer.source, start, lexer.offset)

        if escaped? do
          {lexer, parts} = scan_identifier_parts(lexer, [raw])
          {lexer, parts |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          {lexer, raw}
        end
      end

    raw = slice(lexer.source, start, lexer.offset)

    cond do
      value == "true" -> token_at(lexer, :boolean, true, raw, start)
      value == "false" -> token_at(lexer, :boolean, false, raw, start)
      value == "null" -> token_at(lexer, :null, nil, raw, start)
      MapSet.member?(@keywords, value) -> token_at(lexer, :keyword, value, raw, start)
      true -> token_at(lexer, :identifier, value, raw, start)
    end
  end

  defp advance_identifier_raw(%{offset: offset, length: length} = lexer) when offset >= length,
    do: {lexer, false}

  defp advance_identifier_raw(%{source: source, offset: start, length: length} = lexer) do
    {offset, reason} = advance_identifier_raw_offset(source, start, length)
    lexer = %{lexer | offset: offset, column: lexer.column + offset - start}

    case reason do
      :escape ->
        {lexer, true}

      :non_ascii ->
        if identifier_part?(codepoint_at(source, offset, length)) do
          advance_identifier_raw(advance(lexer))
        else
          {lexer, false}
        end

      :stop ->
        {lexer, false}
    end
  end

  defp advance_identifier_raw_offset(source, offset, length) when offset < length do
    byte = :binary.at(source, offset)

    cond do
      ascii_identifier_part?(byte) ->
        advance_identifier_raw_offset(source, offset + 1, length)

      byte == ?\\ and byte_at(source, offset + 1, length) == ?u ->
        {offset, :escape}

      byte < 0x80 ->
        {offset, :stop}

      true ->
        {offset, :non_ascii}
    end
  end

  defp advance_identifier_raw_offset(_source, offset, _length), do: {offset, :stop}

  defp scan_identifier_parts(lexer, acc) do
    ch = current(lexer)

    cond do
      ch == ?\\ and peek(lexer, 1) == ?u ->
        scan_identifier_escape(lexer, acc)

      identifier_part?(ch) ->
        scan_identifier_parts(advance(lexer), [<<ch::utf8>> | acc])

      true ->
        {lexer, acc}
    end
  end

  defp scan_identifier_escape(lexer, acc) do
    cond do
      unicode_brace_escape?(lexer) ->
        scan_braced_identifier_escape(lexer, acc)

      true ->
        case binary_part(lexer.source, lexer.offset, min(6, lexer.length - lexer.offset)) do
          <<"\\u", hex::binary-size(4)>> ->
            case Integer.parse(hex, 16) do
              {codepoint, ""} when codepoint in 0..0xD7FF or codepoint in 0xE000..0x10FFFF ->
                scan_identifier_parts(advance_bytes(lexer, 6), [<<codepoint::utf8>> | acc])

              _ ->
                {add_error(lexer, "invalid unicode escape in identifier") |> advance_bytes(2),
                 acc}
            end

          _ ->
            {add_error(lexer, "invalid unicode escape in identifier") |> advance_bytes(2), acc}
        end
    end
  end

  defp unicode_brace_escape?(lexer) do
    byte_at(lexer.source, lexer.offset, lexer.length) == ?\\ and
      byte_at(lexer.source, lexer.offset + 1, lexer.length) == ?u and
      byte_at(lexer.source, lexer.offset + 2, lexer.length) == ?{
  end

  defp scan_braced_identifier_escape(lexer, acc) do
    rest = binary_part(lexer.source, lexer.offset + 3, lexer.length - lexer.offset - 3)

    case :binary.match(rest, "}") do
      {finish, 1} ->
        hex = binary_part(rest, 0, finish)

        case Integer.parse(hex, 16) do
          {codepoint, ""} when codepoint in 0..0xD7FF or codepoint in 0xE000..0x10FFFF ->
            scan_identifier_parts(advance_bytes(lexer, finish + 4), [<<codepoint::utf8>> | acc])

          _ ->
            {add_error(lexer, "invalid unicode escape in identifier") |> advance_bytes(3), acc}
        end

      :nomatch ->
        {add_error(lexer, "invalid unicode escape in identifier") |> advance_bytes(3), acc}
    end
  end

  defp scan_number(lexer) do
    start = lexer.offset

    lexer =
      cond do
        number_prefix?(lexer, ?x, ?X) ->
          lexer |> advance_bytes(2) |> advance_while(&(hex_digit?(&1) or &1 == ?_))

        number_prefix?(lexer, ?b, ?B) ->
          lexer |> advance_bytes(2) |> advance_while(&(&1 in [?0, ?1, ?_]))

        number_prefix?(lexer, ?o, ?O) ->
          lexer |> advance_bytes(2) |> advance_while(&(&1 in ?0..?7 or &1 == ?_))

        true ->
          scan_decimal(lexer)
      end

    lexer = if current(lexer) == ?n, do: advance(lexer), else: lexer
    raw = slice(lexer.source, start, lexer.offset)
    lexer = validate_number_literal(lexer, raw)
    value = parse_number(raw)
    token_at(lexer, :number, value, raw, start)
  end

  defp scan_decimal(lexer) do
    start = lexer.offset
    lexer = advance_while(lexer, &(&1 in ?0..?9 or &1 == ?_))

    lexer =
      if decimal_fraction_start?(lexer, start) do
        lexer |> advance() |> advance_while(&(&1 in ?0..?9 or &1 == ?_))
      else
        lexer
      end

    if current(lexer) in [?e, ?E] do
      exponent = advance(lexer)
      exponent = if current(exponent) in [?+, ?-], do: advance(exponent), else: exponent
      advance_while(exponent, &(&1 in ?0..?9 or &1 == ?_))
    else
      lexer
    end
  end

  defp decimal_fraction_start?(lexer, start) do
    current(lexer) == ?. and not leading_zero_member_access?(lexer, start)
  end

  defp leading_zero_member_access?(lexer, start) do
    raw = slice(lexer.source, start, lexer.offset)
    byte_size(raw) > 1 and String.starts_with?(raw, "0") and identifier_start?(peek(lexer, 1))
  end

  defp parse_number(raw) do
    normalized = String.trim_trailing(raw, "n")

    cond do
      String.starts_with?(normalized, ["0x", "0X"]) ->
        parse_prefixed_int(normalized, 2, 16)

      String.starts_with?(normalized, ["0b", "0B"]) ->
        parse_prefixed_int(normalized, 2, 2)

      String.starts_with?(normalized, ["0o", "0O"]) ->
        parse_prefixed_int(normalized, 2, 8)

      String.contains?(normalized, [".", "e", "E"]) ->
        normalized
        |> String.replace("_", "")
        |> normalize_float_literal()
        |> Float.parse()
        |> elem(0)

      true ->
        normalized |> String.replace("_", "") |> Integer.parse() |> elem(0)
    end
  rescue
    _ -> :nan
  end

  defp normalize_float_literal(<<".", _::binary>> = raw), do: "0" <> raw
  defp normalize_float_literal(raw), do: raw

  defp parse_prefixed_int(raw, trim, base) do
    raw
    |> binary_part(trim, byte_size(raw) - trim)
    |> String.replace("_", "")
    |> Integer.parse(base)
    |> elem(0)
  end

  defp number_prefix?(lexer, lower, upper) do
    byte_at(lexer.source, lexer.offset, lexer.length) == ?0 and
      byte_at(lexer.source, lexer.offset + 1, lexer.length) in [lower, upper]
  end

  defp validate_number_literal(lexer, raw) do
    normalized = String.trim_trailing(raw, "n")
    prefixed? = prefixed_number?(raw)

    cond do
      String.ends_with?(raw, "n") and not prefixed? and String.contains?(raw, [".", "e", "E"]) ->
        add_error(lexer, "invalid bigint literal")

      String.ends_with?(raw, ".") and identifier_start?(current(lexer)) ->
        add_error(lexer, "invalid number literal")

      bare_number_prefix?(normalized) ->
        add_error(lexer, "invalid number literal")

      prefixed? and identifier_part?(current(lexer)) ->
        add_error(lexer, "invalid number literal")

      not prefixed? and String.match?(normalized, ~r/[eE][+-]?(_|$)/) ->
        add_error(lexer, "invalid number literal")

      not prefixed? and String.match?(raw, ~r/^0[0-9]*_/) ->
        add_error(lexer, "invalid numeric separator")

      prefixed_numeric_separator_after_prefix?(raw) ->
        add_error(lexer, "invalid numeric separator")

      String.starts_with?(normalized, "_") or String.ends_with?(normalized, "_") ->
        add_error(lexer, "invalid numeric separator")

      String.contains?(raw, "__") ->
        add_error(lexer, "invalid numeric separator")

      true ->
        lexer
    end
  end

  defp prefixed_number?(<<"0", prefix, _rest::binary>>) when prefix in [?x, ?X, ?b, ?B, ?o, ?O],
    do: true

  defp prefixed_number?(_raw), do: false

  defp bare_number_prefix?(prefix) when prefix in ["0x", "0X", "0b", "0B", "0o", "0O"], do: true
  defp bare_number_prefix?(_raw), do: false

  defp prefixed_numeric_separator_after_prefix?(<<"0", prefix, "_", _rest::binary>>)
       when prefix in [?x, ?X, ?b, ?B, ?o, ?O],
       do: true

  defp prefixed_numeric_separator_after_prefix?(_raw), do: false

  defp scan_template(lexer) do
    start = lexer.offset
    lexer = lexer |> advance() |> scan_template_body(start)
    raw = slice(lexer.source, start, lexer.offset)
    token_at(lexer, :template, raw, raw, start)
  end

  defp scan_template_body(lexer, start) do
    cond do
      eof?(lexer) ->
        add_error(lexer, "unterminated template literal")

      current(lexer) == ?\\ ->
        lexer |> advance() |> advance() |> scan_template_body(start)

      current(lexer) == ?` ->
        advance(lexer)

      current(lexer) == ?$ and peek(lexer, 1) == ?{ ->
        lexer |> advance_bytes(2) |> scan_template_expr(start, 1) |> scan_template_body(start)

      true ->
        lexer |> advance() |> scan_template_body(start)
    end
  end

  defp scan_template_expr(lexer, _start, 0), do: lexer

  defp scan_template_expr(lexer, start, depth) do
    cond do
      eof?(lexer) ->
        add_error(lexer, "unterminated template expression")

      current(lexer) in [?", ?'] ->
        {_token, lexer} = scan_string(lexer, current(lexer))
        lexer |> Map.put(:last_token, nil) |> scan_template_expr(start, depth)

      current(lexer) == ?` ->
        lexer |> advance() |> scan_template_body(start) |> scan_template_expr(start, depth)

      current(lexer) == ?{ ->
        lexer |> advance() |> scan_template_expr(start, depth + 1)

      current(lexer) == ?} ->
        lexer = advance(lexer)
        if depth == 1, do: lexer, else: scan_template_expr(lexer, start, depth - 1)

      true ->
        lexer |> advance() |> scan_template_expr(start, depth)
    end
  end

  defp scan_regexp(lexer) do
    start = lexer.offset
    lexer = advance(lexer)
    scan_regexp_body(lexer, start, false)
  end

  defp scan_regexp_body(lexer, start, in_class?) do
    cond do
      eof?(lexer) ->
        raw = slice(lexer.source, start, lexer.offset)
        lexer = add_error(lexer, "unterminated regular expression literal")
        token_at(lexer, :regexp, %{pattern: raw, flags: ""}, raw, start)

      line_terminator?(current(lexer)) ->
        raw = slice(lexer.source, start, lexer.offset)
        lexer = add_error(lexer, "unterminated regular expression literal")
        token_at(lexer, :regexp, %{pattern: raw, flags: ""}, raw, start)

      current(lexer) == ?\\ ->
        lexer |> advance() |> advance() |> scan_regexp_body(start, in_class?)

      current(lexer) == ?[ ->
        lexer |> advance() |> scan_regexp_body(start, true)

      current(lexer) == ?] and in_class? ->
        lexer |> advance() |> scan_regexp_body(start, false)

      current(lexer) == ?/ and not in_class? ->
        lexer = advance(lexer)
        lexer = advance_while(lexer, &identifier_part?/1)
        raw = slice(lexer.source, start, lexer.offset)
        {pattern, flags} = split_regexp(raw)
        token_at(lexer, :regexp, %{pattern: pattern, flags: flags}, raw, start)

      true ->
        lexer |> advance() |> scan_regexp_body(start, in_class?)
    end
  end

  defp split_regexp(raw) do
    body = binary_part(raw, 1, byte_size(raw) - 1)
    idx = closing_regexp_slash(body, 0, false)
    pattern = binary_part(body, 0, idx)
    flags = binary_part(body, idx + 1, byte_size(body) - idx - 1)
    {pattern, flags}
  end

  defp closing_regexp_slash(<<>>, idx, _in_class?), do: idx

  defp closing_regexp_slash(<<?\\, _escaped, rest::binary>>, idx, in_class?),
    do: closing_regexp_slash(rest, idx + 2, in_class?)

  defp closing_regexp_slash(<<?[, rest::binary>>, idx, _in_class?),
    do: closing_regexp_slash(rest, idx + 1, true)

  defp closing_regexp_slash(<<?], rest::binary>>, idx, true),
    do: closing_regexp_slash(rest, idx + 1, false)

  defp closing_regexp_slash(<<?/, _rest::binary>>, idx, false), do: idx

  defp closing_regexp_slash(<<_ch::utf8, rest::binary>>, idx, in_class?),
    do: closing_regexp_slash(rest, idx + 1, in_class?)

  defp scan_string(lexer, quote) do
    start = lexer.offset
    lexer = advance(lexer)
    scan_string_body(lexer, quote, start, [])
  end

  defp scan_string_body(lexer, quote, start, acc) do
    cond do
      eof?(lexer) ->
        raw = slice(lexer.source, start, lexer.offset)
        lexer = add_error(lexer, "unterminated string literal")
        token_at(lexer, :string, acc |> Enum.reverse() |> IO.iodata_to_binary(), raw, start)

      current(lexer) == quote ->
        lexer = advance(lexer)
        raw = slice(lexer.source, start, lexer.offset)
        token_at(lexer, :string, acc |> Enum.reverse() |> IO.iodata_to_binary(), raw, start)

      string_line_terminator?(current(lexer)) ->
        raw = slice(lexer.source, start, lexer.offset)
        lexer = add_error(lexer, "unterminated string literal")
        token_at(lexer, :string, acc |> Enum.reverse() |> IO.iodata_to_binary(), raw, start)

      current(lexer) == ?\\ ->
        {escaped, lexer} = scan_escape(advance(lexer))
        scan_string_body(lexer, quote, start, [escaped | acc])

      true ->
        ch = current(lexer)
        scan_string_body(advance(lexer), quote, start, [<<ch::utf8>> | acc])
    end
  end

  defp scan_escape(lexer) do
    case current(lexer) do
      ?n -> {"\n", advance(lexer)}
      ?r -> {"\r", advance(lexer)}
      ?t -> {"\t", advance(lexer)}
      ?b -> {"\b", advance(lexer)}
      ?f -> {"\f", advance(lexer)}
      ?v -> {<<11>>, advance(lexer)}
      ?0 -> {<<0>>, advance(lexer)}
      ?x -> scan_fixed_string_escape(advance(lexer), 2)
      ?u -> scan_unicode_string_escape(advance(lexer))
      ch when ch in [?\n, ?\r, 0x2028, 0x2029] -> {"", consume_line_terminator(lexer)}
      ch when is_integer(ch) -> {<<ch::utf8>>, advance(lexer)}
      nil -> {"", lexer}
    end
  end

  defp scan_fixed_string_escape(lexer, digits) do
    case take_hex_escape(lexer, digits) do
      {:ok, codepoint, lexer} -> {string_escape_value(codepoint), lexer}
      :error -> {"", add_error(lexer, "invalid string escape")}
    end
  end

  defp scan_unicode_string_escape(lexer) do
    cond do
      current(lexer) == ?{ ->
        scan_braced_string_escape(advance(lexer))

      true ->
        scan_fixed_string_escape(lexer, 4)
    end
  end

  defp scan_braced_string_escape(lexer) do
    rest = binary_part(lexer.source, lexer.offset, lexer.length - lexer.offset)

    case :binary.match(rest, "}") do
      {finish, 1} ->
        hex = binary_part(rest, 0, finish)

        case Integer.parse(hex, 16) do
          {codepoint, ""} when codepoint in 0..0x10FFFF ->
            {string_escape_value(codepoint), advance_bytes(lexer, finish + 1)}

          _ ->
            {"", add_error(lexer, "invalid string escape")}
        end

      :nomatch ->
        {"", add_error(lexer, "invalid string escape")}
    end
  end

  defp take_hex_escape(lexer, digits) do
    if lexer.offset + digits <= lexer.length do
      hex = binary_part(lexer.source, lexer.offset, digits)

      case Integer.parse(hex, 16) do
        {codepoint, ""} when codepoint in 0..0xFFFF ->
          {:ok, codepoint, advance_bytes(lexer, digits)}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp string_escape_value(codepoint) when codepoint in 0xD800..0xDFFF, do: <<codepoint::16>>
  defp string_escape_value(codepoint), do: <<codepoint::utf8>>

  defp scan_punctuator(lexer) do
    case punctuator_at(lexer) do
      nil ->
        raw = slice(lexer.source, lexer.offset, lexer.offset + 1)
        lexer = lexer |> add_error("unexpected character #{inspect(raw)}") |> advance()
        token_at(lexer, :punctuator, raw, raw, lexer.offset - 1)

      punctuator ->
        start = lexer.offset
        lexer = advance_bytes(lexer, byte_size(punctuator))
        token_at(lexer, :punctuator, punctuator, punctuator, start)
    end
  end

  defp punctuator_at(lexer) do
    rest = binary_part(lexer.source, lexer.offset, lexer.length - lexer.offset)

    case rest do
      <<">>>=", _::binary>> -> ">>>="
      <<"===", _::binary>> -> "==="
      <<"!==", _::binary>> -> "!=="
      <<">>>", _::binary>> -> ">>>"
      <<"<<=", _::binary>> -> "<<="
      <<">>=", _::binary>> -> ">>="
      <<"**=", _::binary>> -> "**="
      <<"&&=", _::binary>> -> "&&="
      <<"||=", _::binary>> -> "||="
      <<"??=", _::binary>> -> "??="
      <<"...", _::binary>> -> "..."
      <<"=>", _::binary>> -> "=>"
      <<"++", _::binary>> -> "++"
      <<"--", _::binary>> -> "--"
      <<"==", _::binary>> -> "=="
      <<"!=", _::binary>> -> "!="
      <<"<=", _::binary>> -> "<="
      <<">=", _::binary>> -> ">="
      <<"&&", _::binary>> -> "&&"
      <<"||", _::binary>> -> "||"
      <<"??", _::binary>> -> "??"
      <<"?.", next, _::binary>> when next not in ?0..?9 -> "?."
      <<"?.">> -> "?."
      <<"**", _::binary>> -> "**"
      <<"<<", _::binary>> -> "<<"
      <<">>", _::binary>> -> ">>"
      <<"+=", _::binary>> -> "+="
      <<"-=", _::binary>> -> "-="
      <<"*=", _::binary>> -> "*="
      <<"/=", _::binary>> -> "/="
      <<"%=", _::binary>> -> "%="
      <<"&=", _::binary>> -> "&="
      <<"|=", _::binary>> -> "|="
      <<"^=", _::binary>> -> "^="
      <<ch, _::binary>> when ch in ~c"{}()[].;,<>+-*/%&|^!~?:#=@" -> <<ch>>
      _ -> nil
    end
  end

  defp skip_trivia(%{offset: offset, length: length} = lexer) when offset >= length, do: lexer

  defp skip_trivia(%{source: source, offset: offset} = lexer) do
    byte = :binary.at(source, offset)

    cond do
      byte in [?\s, ?\t, ?\v, ?\f] ->
        lexer |> advance() |> skip_trivia()

      byte == ?\n or byte == ?\r ->
        lexer |> consume_line_terminator() |> skip_trivia()

      byte >= 0x80 and unicode_trivia?(current(lexer)) ->
        lexer |> advance() |> skip_trivia()

      offset == 0 and byte == ?# and byte_at(source, offset + 1, lexer.length) == ?! ->
        lexer |> skip_hashbang_comment() |> skip_trivia()

      byte == ?/ and byte_at(source, offset + 1, lexer.length) == ?/ ->
        lexer |> skip_line_comment() |> skip_trivia()

      byte == ?/ and byte_at(source, offset + 1, lexer.length) == ?* ->
        lexer |> skip_block_comment() |> skip_trivia()

      true ->
        lexer
    end
  end

  defp skip_hashbang_comment(lexer) do
    lexer
    |> advance_bytes(2)
    |> advance_until(fn ch -> ch == nil or line_terminator?(ch) end)
  end

  defp skip_line_comment(lexer) do
    lexer
    |> advance_bytes(2)
    |> advance_until(fn ch -> ch == nil or line_terminator?(ch) end)
  end

  defp skip_block_comment(%{source: source, offset: offset, length: length} = lexer) do
    start = offset + 2
    rest = binary_part(source, start, length - start)

    case :binary.match(rest, "*/") do
      :nomatch ->
        lexer
        |> advance_bytes(2)
        |> add_error("unterminated block comment")

      {finish, 2} ->
        skipped = binary_part(source, offset, finish + 4)
        {line_delta, column} = comment_position(skipped, lexer.column)

        %{
          lexer
          | offset: offset + byte_size(skipped),
            line: lexer.line + line_delta,
            column: column,
            pending_line_terminator?: lexer.pending_line_terminator? or line_delta > 0
        }
    end
  end

  defp comment_position(skipped, initial_column) do
    skipped
    |> :binary.bin_to_list()
    |> Enum.reduce({0, initial_column}, fn
      byte, {lines, _column} when byte in [?\n, ?\r] -> {lines + 1, 0}
      _byte, {lines, column} -> {lines, column + 1}
    end)
  end

  defp token_at(lexer, type, value, raw, start) do
    token = %Token{
      type: type,
      value: value,
      raw: raw,
      start: start,
      finish: lexer.offset,
      line: lexer.token_start_line,
      column: lexer.token_start_column,
      before_line_terminator?: lexer.pending_line_terminator?
    }

    {token, %{lexer | pending_line_terminator?: false, last_token: token}}
  end

  defp token(lexer, type, value, raw, start), do: token_at(lexer, type, value, raw, start)

  defp add_error(lexer, message) do
    error = %Error{message: message, line: lexer.line, column: lexer.column, offset: lexer.offset}
    %{lexer | errors: [error | lexer.errors]}
  end

  defp advance_until(lexer, pred) do
    if pred.(current(lexer)), do: lexer, else: lexer |> advance() |> advance_until(pred)
  end

  defp advance_while(lexer, pred) do
    if pred.(current(lexer)), do: lexer |> advance() |> advance_while(pred), else: lexer
  end

  defp advance_bytes(lexer, 0), do: lexer
  defp advance_bytes(lexer, count), do: lexer |> advance() |> advance_bytes(count - 1)

  defp advance(%{offset: offset, length: length} = lexer) when offset >= length, do: lexer

  defp advance(%{source: source, offset: offset} = lexer) do
    byte = :binary.at(source, offset)

    cond do
      byte == ?\n or byte == ?\r ->
        %{
          lexer
          | offset: offset + 1,
            line: lexer.line + 1,
            column: 0,
            pending_line_terminator?: true
        }

      byte < 0x80 ->
        %{lexer | offset: offset + 1, column: lexer.column + 1}

      true ->
        ch = codepoint_at(source, offset, lexer.length)
        size = utf8_size(ch)

        if line_terminator?(ch) do
          %{
            lexer
            | offset: offset + size,
              line: lexer.line + 1,
              column: 0,
              pending_line_terminator?: true
          }
        else
          %{lexer | offset: offset + size, column: lexer.column + 1}
        end
    end
  end

  defp consume_line_terminator(lexer) do
    if byte_at(lexer.source, lexer.offset, lexer.length) == ?\r and
         byte_at(lexer.source, lexer.offset + 1, lexer.length) == ?\n,
       do: advance_bytes(lexer, 2),
       else: advance(lexer)
  end

  defp current(%{source: source, offset: offset, length: length}) do
    codepoint_at(source, offset, length)
  end

  defp peek(%{source: source, offset: offset, length: length}, relative) do
    codepoint_at(source, offset + relative, length)
  end

  defp codepoint_at(_source, offset, length) when offset >= length, do: nil

  defp codepoint_at(source, offset, length) do
    byte = :binary.at(source, offset)

    if byte < 0x80 do
      byte
    else
      case binary_part(source, offset, length - offset) do
        <<ch::utf8, _::binary>> -> ch
        <<byte, _::binary>> -> byte
      end
    end
  end

  defp byte_at(_source, offset, length) when offset >= length, do: nil
  defp byte_at(source, offset, _length), do: :binary.at(source, offset)

  defp eof?(lexer), do: lexer.offset >= lexer.length

  defp slice(source, start, finish), do: binary_part(source, start, finish - start)

  defp ascii_identifier_part?(byte)
       when (byte >= ?a and byte <= ?z) or (byte >= ?A and byte <= ?Z) or
              (byte >= ?0 and byte <= ?9) or byte == ?_ or byte == ?$,
       do: true

  defp ascii_identifier_part?(_byte), do: false

  defp identifier_start?(nil), do: false
  defp identifier_start?(?_), do: true
  defp identifier_start?(?$), do: true
  defp identifier_start?(ch), do: ch in ?a..?z or ch in ?A..?Z or ch > 0x7F

  defp identifier_part?(nil), do: false
  defp identifier_part?(ch), do: identifier_start?(ch) or ch in ?0..?9

  defp regexp_allowed?(%{last_token: nil}), do: true

  defp regexp_allowed?(%{last_token: %Token{type: type}})
       when type in [:identifier, :number, :string, :regexp, :boolean, :null],
       do: false

  defp regexp_allowed?(%{last_token: %Token{type: :keyword, value: value}}),
    do: not MapSet.member?(@identifier_like_keywords, value)

  defp regexp_allowed?(%{last_token: %Token{value: value}}) when value in [")", "]", "++", "--"],
    do: false

  defp regexp_allowed?(%{last_token: %Token{value: "}"}} = lexer),
    do: not division_rhs_after_slash?(lexer)

  defp regexp_allowed?(_lexer), do: true

  defp division_rhs_after_slash?(lexer) do
    rhs_offset = skip_horizontal_space_after_slash(lexer, lexer.offset + 1)
    rhs_offset > lexer.offset + 1 and division_rhs_start?(rhs_offset, lexer)
  end

  defp skip_horizontal_space_after_slash(lexer, offset) when offset < lexer.length do
    case byte_at(lexer.source, offset, lexer.length) do
      byte when byte in [?\s, ?\t, ?\v, ?\f] ->
        skip_horizontal_space_after_slash(lexer, offset + 1)

      _ ->
        offset
    end
  end

  defp skip_horizontal_space_after_slash(_lexer, offset), do: offset

  defp division_rhs_start?(offset, lexer) when offset < lexer.length do
    ch = codepoint_at(lexer.source, offset, lexer.length)
    ch in [?{, ?(, ?[, ?", ?', ?+, ?-, ?!, ?~, ?/] or ch in ?0..?9 or identifier_start?(ch)
  end

  defp division_rhs_start?(_offset, _lexer), do: false

  defp hex_digit?(ch), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F
  defp string_line_terminator?(ch), do: ch in [?\n, ?\r]
  defp line_terminator?(ch), do: ch in [?\n, ?\r, 0x2028, 0x2029]
  defp unicode_trivia?(ch), do: line_terminator?(ch) or ch in [0x00A0, 0xFEFF]
  defp utf8_size(ch) when ch < 0x80, do: 1
  defp utf8_size(ch) when ch < 0x800, do: 2
  defp utf8_size(ch) when ch < 0x10000, do: 3
  defp utf8_size(_ch), do: 4
end
