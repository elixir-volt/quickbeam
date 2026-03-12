defmodule Pegasus.Grammar do
  @moduledoc false

  # produces a fully parsed grammar.
  #
  # ```
  # Grammar         <- Spacing Definition+ EndOfFile
  # Definition      <- Identifier LEFTARROW Expression
  # ```

  import NimbleParsec

  alias Pegasus.Components
  alias Pegasus.Expression
  alias Pegasus.Identifier
  alias Pegasus.Tokens

  def parser do
    Components.spacing()
    |> times(
      Identifier.parser(empty())
      |> Tokens.leftarrow()
      |> Expression.parser()
      |> post_traverse({__MODULE__, :collate, []}),
      min: 1
    )
    |> Components.end_of_file()
  end

  def collate(rest, [parser, :leftarrow, {:identifier, name} | args_rest], context, _, _) do
    {rest, [{name, parser} | args_rest], context}
  end
end
