defmodule QuickBEAM.JS.Parser.Lexer.Regexp.Escapes do
  @moduledoc "Unicode, decimal, and identity escape validation."

  def regexp_unicode_escape_error(pattern, flags) do
    if is_binary(flags) and (binary_part?(flags, "u") or binary_part?(flags, "v")) do
      regexp_unicode_escape_error_in_pattern(pattern, 0)
    end
  end

  defp regexp_unicode_escape_error_in_pattern(pattern, offset) when offset >= byte_size(pattern),
    do: regexp_lone_left_brace_error(pattern, 0)

  defp regexp_unicode_escape_error_in_pattern(pattern, offset) do
    case :binary.match(pattern, "\\", scope: {offset, byte_size(pattern) - offset}) do
      :nomatch ->
        regexp_unicode_escape_error_in_pattern(pattern, byte_size(pattern))

      {index, 1} ->
        next = index + 1

        cond do
          next >= byte_size(pattern) ->
            "invalid escape sequence in regular expression"

          :binary.at(pattern, next) == ?u ->
            validate_regexp_unicode_escape(pattern, next + 1) ||
              regexp_unicode_escape_error_in_pattern(pattern, next + 1)

          :binary.at(pattern, next) in ?1..?9 ->
            regexp_decimal_escape_error(pattern, next)

          :binary.at(pattern, next) in [?p, ?P] and next + 1 < byte_size(pattern) and
              :binary.at(pattern, next + 1) == ?{ ->
            regexp_unicode_escape_error_in_pattern(
              pattern,
              skip_regexp_braced_escape(pattern, next + 2)
            )

          :binary.at(pattern, next) == ?c and
              (next + 1 >= byte_size(pattern) or not ascii_letter?(:binary.at(pattern, next + 1))) ->
            "invalid escape sequence in regular expression"

          regexp_invalid_identity_escape?(:binary.at(pattern, next)) ->
            "invalid escape sequence in regular expression"

          true ->
            regexp_unicode_escape_error_in_pattern(pattern, next + 1)
        end
    end
  end

  defp validate_regexp_unicode_escape(pattern, index) do
    cond do
      index < byte_size(pattern) and :binary.at(pattern, index) == ?{ ->
        validate_regexp_braced_unicode_escape(pattern, index + 1)

      index + 4 <= byte_size(pattern) and
          Enum.all?(index..(index + 3), &hex_digit_byte?(:binary.at(pattern, &1))) ->
        nil

      true ->
        "invalid escape sequence in regular expression"
    end
  end

  defp validate_regexp_braced_unicode_escape(pattern, index),
    do: validate_regexp_braced_unicode_escape(pattern, index, false, 0)

  defp validate_regexp_braced_unicode_escape(pattern, index, _saw_digit?, _codepoint)
       when index >= byte_size(pattern),
       do: "invalid escape sequence in regular expression"

  defp validate_regexp_braced_unicode_escape(pattern, index, saw_digit?, codepoint) do
    ch = :binary.at(pattern, index)

    cond do
      ch == ?} and saw_digit? and codepoint <= 0x10FFFF ->
        nil

      ch == ?} ->
        "invalid escape sequence in regular expression"

      hex_digit_byte?(ch) ->
        validate_regexp_braced_unicode_escape(
          pattern,
          index + 1,
          true,
          codepoint * 16 + hex_digit_value(ch)
        )

      true ->
        "invalid escape sequence in regular expression"
    end
  end

  defp skip_regexp_braced_escape(pattern, offset) when offset >= byte_size(pattern), do: offset

  defp skip_regexp_braced_escape(pattern, offset) do
    if :binary.at(pattern, offset) == ?} do
      offset + 1
    else
      skip_regexp_braced_escape(pattern, offset + 1)
    end
  end

  defp regexp_decimal_escape_error(pattern, index) do
    {number, _next_offset} = read_decimal_escape_number(pattern, index, 0)

    if number > regexp_capture_count(pattern) do
      "back reference out of range in regular expression"
    end
  end

  defp read_decimal_escape_number(pattern, offset, value)
       when offset >= byte_size(pattern),
       do: {value, offset}

  defp read_decimal_escape_number(pattern, offset, value) do
    ch = :binary.at(pattern, offset)

    if ch in ?0..?9 do
      read_decimal_escape_number(pattern, offset + 1, value * 10 + ch - ?0)
    else
      {value, offset}
    end
  end

  defp regexp_capture_count(pattern), do: regexp_capture_count(pattern, 0, 0)

  defp regexp_capture_count(pattern, offset, count) when offset >= byte_size(pattern), do: count

  defp regexp_capture_count(pattern, offset, count) do
    cond do
      :binary.at(pattern, offset) == ?\\ ->
        regexp_capture_count(pattern, min(offset + 2, byte_size(pattern)), count)

      offset + 1 < byte_size(pattern) and :binary.at(pattern, offset) == ?( and
        :binary.at(pattern, offset + 1) == ?? and
          not (offset + 2 < byte_size(pattern) and :binary.at(pattern, offset + 2) == ?<) ->
        regexp_capture_count(pattern, offset + 2, count)

      :binary.at(pattern, offset) == ?( ->
        regexp_capture_count(pattern, offset + 1, count + 1)

      true ->
        regexp_capture_count(pattern, offset + 1, count)
    end
  end

  defp regexp_lone_left_brace_error(pattern, offset) when offset >= byte_size(pattern), do: nil

  defp regexp_lone_left_brace_error(pattern, offset) do
    ch = :binary.at(pattern, offset)

    cond do
      ch == ?\\ and offset + 2 < byte_size(pattern) and
        :binary.at(pattern, offset + 1) in [?p, ?P] and
          :binary.at(pattern, offset + 2) == ?{ ->
        regexp_lone_left_brace_error(pattern, skip_regexp_braced_escape(pattern, offset + 3))

      ch == ?\\ and offset + 2 < byte_size(pattern) and :binary.at(pattern, offset + 1) == ?u and
          :binary.at(pattern, offset + 2) == ?{ ->
        regexp_lone_left_brace_error(pattern, skip_regexp_braced_escape(pattern, offset + 3))

      ch == ?\\ ->
        regexp_lone_left_brace_error(pattern, min(offset + 2, byte_size(pattern)))

      ch == ?{ and offset > 0 and :binary.at(pattern, offset - 1) in [?p, ?P] ->
        regexp_lone_left_brace_error(pattern, offset + 1)

      ch == ?{ and
          (offset + 1 >= byte_size(pattern) or :binary.at(pattern, offset + 1) not in ?0..?9) ->
        "invalid escape sequence in regular expression"

      true ->
        regexp_lone_left_brace_error(pattern, offset + 1)
    end
  end

  defp regexp_invalid_identity_escape?(ch),
    do: (ch in ?a..?z or ch in ?A..?Z) and ch not in ~c"bBdDsSfFnNrRtTvVcCwWxXuUpPkK"

  defp ascii_letter?(ch), do: ch in ?a..?z or ch in ?A..?Z
  defp hex_digit_byte?(ch), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F
  defp hex_digit_value(ch) when ch in ?0..?9, do: ch - ?0
  defp hex_digit_value(ch) when ch in ?a..?f, do: ch - ?a + 10
  defp hex_digit_value(ch) when ch in ?A..?F, do: ch - ?A + 10

  defp binary_part?(binary, part), do: :binary.match(binary, part) != :nomatch
end
