defmodule QuickBEAM.VM.Runtime.Boundary.Thenable do
  @moduledoc """
  Tracks invocation of a foreign thenable's `then` method during assimilation.
  """

  @enforce_keys [:promise, :depth]
  defstruct [:promise, :depth]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.Runtime.Promise.Reference.t(),
          depth: non_neg_integer()
        }
end
