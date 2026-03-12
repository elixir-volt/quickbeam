defmodule Pegasus.Primary do
  @moduledoc false

  # Produces a "primary" parser.  This is a single item which
  #
  # ```peg
  # Primary        <- Identifier !LEFTARROW
  #               / OPEN Expression CLOSE
  #               / Literal
  #               / Class
  #               / DOT
  #               / Action
  #               / BEGIN Expression END
  # ```

  import NimbleParsec
  alias Pegasus.Expression
  alias Pegasus.Identifier
  alias Pegasus.Literal
  alias Pegasus.Class
  alias Pegasus.Tokens

  def parser(previous \\ empty()) do
    previous
    |> choice([
      bare_identifier(),
      paren_expression(),
      Literal.parser(),
      Class.parser(),
      Tokens.dot(),
      tagged_expression()
    ])
  end

  defp bare_identifier do
    empty()
    |> Identifier.parser()
    |> lookahead_not(Tokens.leftarrow())
  end

  defp paren_expression do
    tag(
      ignore(Tokens.open())
      |> parsec({Expression, :expression})
      |> ignore(Tokens.close()),
      :collect
    )
    |> post_traverse({__MODULE__, :_group, [:ungroup]})
  end

  defp tagged_expression do
    tag(
      ignore(Tokens.begin())
      |> parsec({Expression, :expression})
      |> ignore(Tokens.ender()),
      :collect
    )
    |> post_traverse({__MODULE__, :_group, [:extract]})
  end

  def _group(rest, [{:collect, [inner_args]} | args_rest], context, _, _, action) do
    {rest, [{action, inner_args} | args_rest], context}
  end
end
