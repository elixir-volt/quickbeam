defmodule QuickBEAM.VM.ThenGetterBoundary do
  @moduledoc """
  Tracks the JavaScript `then` property getter used during Promise resolution.

  Getter completion either invokes the returned callable as a thenable or
  fulfills the target Promise directly when the property is not callable.
  """

  @enforce_keys [:promise, :thenable, :depth]
  defstruct [:promise, :thenable, :depth, :continuation]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          thenable: QuickBEAM.VM.Reference.t(),
          depth: non_neg_integer(),
          continuation: QuickBEAM.VM.Frame.t() | nil
        }
end
