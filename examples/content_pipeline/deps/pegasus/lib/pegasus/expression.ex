defmodule Pegasus.Expression do
  @moduledoc false

  # Produces a "expression" parser.
  #
  # ```peg
  # Expression      <- Sequence ( SLASH Sequence )*
  # ```

  import NimbleParsec

  alias Pegasus.Sequence
  alias Pegasus.Tokens

  require Sequence
  require Tokens

  expression =
    empty()
    |> tag(
      Sequence.parser()
      |> repeat(
        Tokens.slash()
        |> Sequence.parser()
      ),
      :sequences
    )
    |> post_traverse({__MODULE__, :_separate_slashes, []})

  defcombinator(:expression, expression)

  def parser(previous \\ empty()) do
    parsec(previous, {__MODULE__, :expression})
  end

  def _separate_slashes(rest, [{:sequences, sequences} | other_args], context, _, _) do
    choice =
      case by_slashes(sequences) do
        [one_sequence] -> one_sequence
        many_sequences -> [choice: many_sequences]
      end

    {rest, [choice | other_args], context}
  end

  defp by_slashes(sequences, so_far \\ [])

  defp by_slashes([], so_far), do: Enum.reverse(so_far)
  defp by_slashes([:slash, this | rest], so_far), do: by_slashes(rest, [this | so_far])
  defp by_slashes([this | rest], []), do: by_slashes(rest, [this])
end
