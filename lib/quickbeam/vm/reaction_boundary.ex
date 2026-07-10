defmodule QuickBEAM.VM.ReactionBoundary do
  @moduledoc """
  Tracks completion of a running Promise reaction callback.

  It preserves the original settlement for `finally` and identifies the result
  Promise that receives callback completion.
  """

  @enforce_keys [:promise, :depth]
  defstruct [:promise, :depth, mode: :then, original_result: nil]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          depth: non_neg_integer(),
          mode: :then | :finally,
          original_result: {:ok, term()} | {:error, term()} | nil
        }
end
