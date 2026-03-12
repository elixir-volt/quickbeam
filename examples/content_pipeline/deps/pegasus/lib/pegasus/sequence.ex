defmodule Pegasus.Sequence do
  @moduledoc false

  # Collects together parsers for all of the minor tokens for Peg parsers
  #
  # ```peg
  # Sequence        <- Prefix*
  # Prefix          <- AND Action  # <== not implemented
  #                 / ( AND / NOT )? Suffix
  # Suffix          <- Primary ( QUERY / STAR / PLUS )?
  # ```

  alias Pegasus.Tokens
  alias Pegasus.Primary

  import NimbleParsec

  def parser(previous \\ empty()) do
    previous
    |> tag(
      repeat(
        tag(
          optional(choice([Tokens.and(), Tokens.not()]))
          |> Primary.parser()
          |> optional(
            choice([
              Tokens.query(),
              Tokens.star(),
              Tokens.plus()
            ])
          ),
          :one_sequence_item
        )
      ),
      :sequence
    )
    |> post_traverse({__MODULE__, :sequence, []})
  end

  def sequence(rest, [{:sequence, args} | rest_args], context, _, _) do
    new_args = Enum.map(args, &sequence_one/1)
    {rest, [new_args | rest_args], context}
  end

  def sequence_one({:one_sequence_item, [:and | args]}) do
    {:lookahead, sequence_internal(args)}
  end

  def sequence_one({:one_sequence_item, [:not | args]}) do
    {:lookahead_not, sequence_internal(args)}
  end

  def sequence_one({:one_sequence_item, args}), do: sequence_internal(args)

  defp sequence_internal([command, :query]), do: {:optional, command}

  defp sequence_internal([command, :star]), do: {:repeat, command}

  defp sequence_internal([command, :plus]), do: {:times, command}

  defp sequence_internal([command]), do: command
end
