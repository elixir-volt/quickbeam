defmodule Pegasus.Components do
  @moduledoc false

  # tools for the most simple parts of the PEG definition.
  #
  # None of these components *a priori* generate parsers.
  #
  # The following components are defined here:
  #
  # ```peg
  # Range           <- Char '-' Char / Char
  # Char            <- '\\' [abefnrtv'"\[\]\\]
  #                 / '\\' [0-3][0-7][0-7]
  #                 / '\\' [0-7][0-7]?
  #                 / '\\' '-'
  #                 / !'\\' .
  # Spacing         <- ( Space / Comment )*
  # Comment         <- '#' ( !EndOfLine . )* EndOfLine
  # Space           <- ' ' / '\t' / EndOfLine
  # EndOfLine       <- '\r\n' / '\n' / '\r'
  # EndOfFile       <- !.
  # ```

  import NimbleParsec

  def range(previous \\ empty()) do
    choice(previous, [
      tag(char() |> string("-") |> char(), :range)
      |> post_traverse({__MODULE__, :_to_range, []}),
      char()
    ])
  end

  def char(previous \\ empty()) do
    escaped_char = ascii_char(~C(abefnrtv'"[]\-))

    three_digit_octal =
      ascii_char([?0..?3])
      |> ascii_char([?0..?7])
      |> ascii_char([?0..?7])

    two_or_one_digit_octal =
      ascii_char([?0..?7])
      |> optional(ascii_char([?0..?7]))

    escaped =
      tag(
        string("\\")
        |> choice([
          escaped_char,
          three_digit_octal,
          two_or_one_digit_octal
        ]),
        :escaped
      )
      |> post_traverse({__MODULE__, :_parse_escaped, []})

    not_escaped =
      lookahead_not(string("\\"))
      # need to provide *some* dummy variable for utf-8 characters
      |> utf8_char(not: 0)

    choice(previous, [
      escaped,
      not_escaped
    ])
  end

  def spacing(previous \\ empty()) do
    previous
    |> ignore(
      repeat(
        choice([
          space(),
          comment()
        ])
      )
    )
  end

  def comment(previous \\ empty()) do
    previous
    |> concat(string("#"))
    |> repeat(
      lookahead_not(end_of_line())
      |> utf8_char(not: 0)
    )
    |> end_of_line()
  end

  def space(previous \\ empty()) do
    previous
    |> choice([
      ascii_char(~c' \t'),
      end_of_line()
    ])
  end

  def end_of_line(previous \\ empty()) do
    previous
    |> choice([
      string("\n\r"),
      ascii_char(~c'\n\r')
    ])
  end

  def end_of_file(previous \\ empty()) do
    eos(previous)
  end

  @escape_lookup %{
    ?a => ?\a,
    ?b => ?\b,
    ?e => ?\e,
    ?f => ?\f,
    ?n => ?\n,
    ?r => ?\r,
    ?t => ?\t,
    ?v => ?\v,
    ?' => ?',
    ?" => ?",
    ?[ => ?[,
    ?] => ?],
    ?- => ?-,
    92 => 92
  }

  @escape_keys Map.keys(@escape_lookup)

  def _parse_escaped(rest, [{:escaped, ["\\", symbol]} | rest_args], context, _, _)
      when symbol in @escape_keys do
    {rest, [@escape_lookup[symbol] | rest_args], context}
  end

  def _parse_escaped(rest, [{:escaped, ["\\", o1, o2, o3]} | rest_args], context, _, _)
      when o1 in ?0..?3 and o2 in ?0..?7 and o3 in ?0..?7 do
    {rest, [deoctalize([o1, o2, o3]) | rest_args], context}
  end

  def _parse_escaped(rest, [{:escaped, ["\\", o1, o2]} | rest_args], context, _, _)
      when o1 in ?0..?7 and o2 in ?0..?7 do
    {rest, [deoctalize([o1, o2]) | rest_args], context}
  end

  def _parse_escaped(rest, [{:escaped, ["\\", o1]} | rest_args], context, _, _)
      when o1 in ?0..?7 do
    {rest, [deoctalize([o1]) | rest_args], context}
  end

  defp deoctalize(list) do
    list |> :erlang.list_to_integer(8)
  end

  def _to_range(rest, [{:range, [left, "-", right]} | rest_args], context, _, _)
      when left < right do
    {rest, [left..right | rest_args], context}
  end
end
