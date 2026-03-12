defmodule Pegasus.Identifier do
  @moduledoc false

  # Produces a "identifier" parser.
  #
  # the make_parser option should be set to false (default) when the identifier
  # is being assigned, and true when the identifier is being used as part of a
  # parser sequence.
  #
  # ```peg
  # Identifier      <- < IdentStart IdentCont* > Spacing
  # IdentStart      <- [a-zA-Z_]
  # IdentCont       <- IdentStart / [0-9]
  # ```

  alias Pegasus.Components
  import NimbleParsec

  def parser(previous, make_parser \\ false) do
    previous
    |> tag(
      ident_start()
      |> repeat(ident_cont()),
      :identifier
    )
    |> post_traverse({__MODULE__, :to_parser, [make_parser]})
    |> Components.spacing()
  end

  def ident_start do
    ascii_char([?a..?z, ?A..?Z, ?_])
  end

  def ident_cont() do
    ascii_char([?a..?z, ?A..?Z, ?_, ?0..?9])
  end

  def to_parser(rest, [{:identifier, args} | other_args], context, _, _, make_parser) do
    identifier =
      args
      |> IO.iodata_to_binary()
      |> String.to_atom()

    tag = if make_parser, do: :parser, else: :identifier

    {rest, [{tag, identifier} | other_args], context}
  end
end
