defmodule QuickBEAM.VM.Options do
  @moduledoc """
  Validates strict keyword options at VM API and engine boundaries.

  Unknown keys and non-keyword inputs fail explicitly so public and internal
  callers share one deterministic option contract.
  """

  @doc "Validates that an input is a keyword list containing only allowed keys."
  @spec validate(term(), [atom()]) ::
          :ok | {:error, {:invalid_options, term()} | {:unknown_option, atom()}}
  def validate(options, allowed) do
    if Keyword.keyword?(options) do
      validate_keys(Keyword.keys(options), allowed)
    else
      {:error, {:invalid_options, options}}
    end
  end

  defp validate_keys(keys, allowed) do
    case keys -- allowed do
      [] -> :ok
      [unknown | _rest] -> {:error, {:unknown_option, unknown}}
    end
  end
end
