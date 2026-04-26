defmodule QuickBEAM.JS.Parser.Lexer do
  @moduledoc "Hand-written JavaScript lexer used by the experimental QuickBEAM parser."

  alias QuickBEAM.JS.Parser.{Error, Token}

  defstruct source: "",
            offset: 0,
            line: 1,
            column: 0,
            length: 0,
            pending_line_terminator?: false,
            errors: []

  @type t :: %__MODULE__{}

  @keywords MapSet.new(~w[
    break case catch class const continue debugger default delete do else export extends
    finally for function if import in instanceof let new return super switch this throw try
    typeof var void while with yield async await of static get set
  ])

  @punctuators [
                 ">>>=",
                 "===",
                 "!==",
                 ">>>",
                 "<<=",
                 ">>=",
                 "**=",
                 "&&=",
                 "||=",
                 "??=",
                 "=>",
                 "++",
                 "--",
                 "==",
                 "!=",
                 "<=",
                 ">=",
                 "&&",
                 "||",
                 "??",
                 "**",
                 "<<",
                 ">>",
                 "+=",
                 "-=",
                 "*=",
                 "/=",
                 "%=",
                 "&=",
                 "|=",
                 "^=",
                 "...",
                 "{",
                 "}",
                 "(",
                 ")",
                 "[",
                 "]",
                 ".",
                 ";",
                 ",",
                 "<",
                 ">",
                 "+",
                 "-",
                 "*",
                 "/",
                 "%",
                 "&",
                 "|",
                 "^",
                 "!",
                 "~",
                 "?",
                 ":",
                 "="
               ]
               |> Enum.sort_by(&byte_size/1, :desc)

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
      ch in ?0..?9 -> scan_number(lexer)
      ch == ?. -> scan_dot_or_number(lexer)
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
    lexer = advance_while(lexer, &identifier_part?/1)
    raw = slice(lexer.source, start, lexer.offset)

    cond do
      raw == "true" -> token_at(lexer, :boolean, true, raw, start)
      raw == "false" -> token_at(lexer, :boolean, false, raw, start)
      raw == "null" -> token_at(lexer, :null, nil, raw, start)
      MapSet.member?(@keywords, raw) -> token_at(lexer, :keyword, raw, raw, start)
      true -> token_at(lexer, :identifier, raw, raw, start)
    end
  end

  defp scan_number(lexer) do
    start = lexer.offset

    lexer =
      cond do
        starts_with?(lexer, "0x") or starts_with?(lexer, "0X") ->
          lexer |> advance_bytes(2) |> advance_while(&hex_digit?/1)

        starts_with?(lexer, "0b") or starts_with?(lexer, "0B") ->
          lexer |> advance_bytes(2) |> advance_while(&(&1 in [?0, ?1]))

        starts_with?(lexer, "0o") or starts_with?(lexer, "0O") ->
          lexer |> advance_bytes(2) |> advance_while(&(&1 in ?0..?7))

        true ->
          scan_decimal(lexer)
      end

    raw = slice(lexer.source, start, lexer.offset)
    value = parse_number(raw)
    token_at(lexer, :number, value, raw, start)
  end

  defp scan_decimal(lexer) do
    lexer = advance_while(lexer, &(&1 in ?0..?9))

    lexer =
      if current(lexer) == ?. and peek(lexer, 1) != ?. do
        lexer |> advance() |> advance_while(&(&1 in ?0..?9))
      else
        lexer
      end

    if current(lexer) in [?e, ?E] do
      exponent = advance(lexer)
      exponent = if current(exponent) in [?+, ?-], do: advance(exponent), else: exponent
      advance_while(exponent, &(&1 in ?0..?9))
    else
      lexer
    end
  end

  defp parse_number(raw) do
    cond do
      String.starts_with?(raw, ["0x", "0X"]) -> parse_prefixed_int(raw, 2, 16)
      String.starts_with?(raw, ["0b", "0B"]) -> parse_prefixed_int(raw, 2, 2)
      String.starts_with?(raw, ["0o", "0O"]) -> parse_prefixed_int(raw, 2, 8)
      String.contains?(raw, [".", "e", "E"]) -> elem(Float.parse(raw), 0)
      true -> elem(Integer.parse(raw), 0)
    end
  rescue
    _ -> :nan
  end

  defp parse_prefixed_int(raw, trim, base) do
    raw |> binary_part(trim, byte_size(raw) - trim) |> Integer.parse(base) |> elem(0)
  end

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

      line_terminator?(current(lexer)) ->
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
      ch when is_integer(ch) -> {<<ch::utf8>>, advance(lexer)}
      nil -> {"", lexer}
    end
  end

  defp scan_punctuator(lexer) do
    case Enum.find(@punctuators, &starts_with?(lexer, &1)) do
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

  defp skip_trivia(lexer) do
    cond do
      eof?(lexer) -> lexer
      current(lexer) in [?\s, ?\t, ?\v, ?\f] -> lexer |> advance() |> skip_trivia()
      line_terminator?(current(lexer)) -> lexer |> consume_line_terminator() |> skip_trivia()
      starts_with?(lexer, "//") -> lexer |> skip_line_comment() |> skip_trivia()
      starts_with?(lexer, "/*") -> lexer |> skip_block_comment() |> skip_trivia()
      true -> lexer
    end
  end

  defp skip_line_comment(lexer) do
    lexer
    |> advance_bytes(2)
    |> advance_until(fn ch -> ch == nil or line_terminator?(ch) end)
  end

  defp skip_block_comment(lexer) do
    lexer = advance_bytes(lexer, 2)
    skip_block_comment_body(lexer)
  end

  defp skip_block_comment_body(lexer) do
    cond do
      eof?(lexer) -> add_error(lexer, "unterminated block comment")
      starts_with?(lexer, "*/") -> advance_bytes(lexer, 2)
      true -> lexer |> advance() |> skip_block_comment_body()
    end
  end

  defp token_at(lexer, type, value, raw, start) do
    {line, column} = position_for(lexer.source, start)

    token = %Token{
      type: type,
      value: value,
      raw: raw,
      start: start,
      finish: lexer.offset,
      line: line,
      column: column,
      before_line_terminator?: lexer.pending_line_terminator?
    }

    {token, %{lexer | pending_line_terminator?: false}}
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

  defp advance_bytes(lexer, count),
    do: Enum.reduce(1..count, lexer, fn _, acc -> advance(acc) end)

  defp advance(%{offset: offset, length: length} = lexer) when offset >= length, do: lexer

  defp advance(lexer) do
    ch = current(lexer)
    size = byte_size(<<ch::utf8>>)

    if line_terminator?(ch) do
      %{
        lexer
        | offset: lexer.offset + size,
          line: lexer.line + 1,
          column: 0,
          pending_line_terminator?: true
      }
    else
      %{lexer | offset: lexer.offset + size, column: lexer.column + 1}
    end
  end

  defp consume_line_terminator(lexer) do
    if starts_with?(lexer, "\r\n"), do: advance_bytes(lexer, 2), else: advance(lexer)
  end

  defp current(lexer), do: peek(lexer, 0)

  defp peek(%{source: source, offset: offset, length: length}, relative) do
    offset = offset + relative

    if offset >= length do
      nil
    else
      case binary_part(source, offset, length - offset) do
        <<ch::utf8, _::binary>> -> ch
        <<byte, _::binary>> -> byte
      end
    end
  end

  defp eof?(lexer), do: lexer.offset >= lexer.length

  defp starts_with?(lexer, prefix),
    do:
      binary_part(lexer.source, lexer.offset, lexer.length - lexer.offset)
      |> String.starts_with?(prefix)

  defp slice(source, start, finish), do: binary_part(source, start, finish - start)

  defp position_for(source, offset) do
    source
    |> binary_part(0, offset)
    |> String.to_charlist()
    |> Enum.reduce({1, 0}, fn
      ?\n, {line, _column} -> {line + 1, 0}
      ?\r, {line, _column} -> {line + 1, 0}
      0x2028, {line, _column} -> {line + 1, 0}
      0x2029, {line, _column} -> {line + 1, 0}
      _ch, {line, column} -> {line, column + 1}
    end)
  end

  defp identifier_start?(nil), do: false
  defp identifier_start?(?_), do: true
  defp identifier_start?(?$), do: true
  defp identifier_start?(ch), do: ch in ?a..?z or ch in ?A..?Z

  defp identifier_part?(nil), do: false
  defp identifier_part?(ch), do: identifier_start?(ch) or ch in ?0..?9

  defp hex_digit?(ch), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F
  defp line_terminator?(ch), do: ch in [?\n, ?\r, 0x2028, 0x2029]
end
