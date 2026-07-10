defmodule QuickBEAM.VM.ReactionBoundary do
  @moduledoc false

  @enforce_keys [:promise, :depth]
  defstruct [:promise, :depth, mode: :then, original_result: nil]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          depth: non_neg_integer(),
          mode: :then | :finally,
          original_result: {:ok, term()} | {:error, term()} | nil
        }
end
