defmodule Pegasus.Class do
  @moduledoc false

  # Produces a "class" parser.
  #
  # Note that the output of a "class" parser leaves a NimbleParsec parser in the
  # arguments list.
  #
  # ```peg
  # Class           <- '[' < ( !']' Range )* > ']' Spacing
  # ```

  alias Pegasus.Components

  import NimbleParsec

  def parser(previous \\ empty()) do
    previous
    |> tag(
      ignore(string("["))
      |> optional(string("^"))
      |> repeat(
        lookahead_not(string("]"))
        |> Components.range()
      )
      |> ignore(string("]")),
      :class
    )
    |> post_traverse({__MODULE__, :to_parser, []})
    |> Components.spacing()
  end

  def to_parser(rest, [{:class, args} | args_rest], context, _, _) do
    classes =
      case args do
        ["^" | rest] ->
          Enum.map(rest, &{:not, &1})

        args ->
          args
      end

    {rest, [{:char, classes} | args_rest], context}
  end
end
