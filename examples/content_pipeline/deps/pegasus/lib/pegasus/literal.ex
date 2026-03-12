defmodule Pegasus.Literal do
  @moduledoc false

  # Produces a "literal" parser.
  #
  # Note that the output of a "literal" parser leaves a NimbleParsec parser in the
  # arguments list.
  #
  # ```peg
  # Literal         <- ['] < ( !['] Char  )* > ['] Spacing
  #                 / ["] < ( !["] Char  )* > ["] Spacing
  # ```

  alias Pegasus.Components
  import NimbleParsec

  def parser(previous \\ empty()) do
    previous
    |> tag(
      choice([
        quoted_literal(~S(')),
        quoted_literal(~S("))
      ]),
      :literal
    )
    |> post_traverse({__MODULE__, :to_parser, []})
    |> Components.spacing()
  end

  defp quoted_literal(quote_bound) do
    ignore(string(quote_bound))
    |> repeat(
      lookahead_not(string(quote_bound))
      |> Components.char()
    )
    |> ignore(string(quote_bound))
  end

  def to_parser(rest, [{:literal, args} | args_rest], context, _, _) do
    literal = IO.iodata_to_binary(args)

    {rest, [{:literal, literal} | args_rest], context}
  end
end
