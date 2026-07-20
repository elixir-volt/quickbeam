defmodule QuickBEAM.VM.Runtime.Boundary.ThenGetter do
  @moduledoc """
  Tracks the JavaScript `then` property getter used during Promise resolution.

  Getter completion either invokes the returned callable as a thenable or
  fulfills the target Promise directly when the property is not callable.
  """

  @enforce_keys [:promise, :thenable, :depth]
  defstruct [:promise, :thenable, :depth, :continuation]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.Runtime.Promise.Reference.t(),
          thenable: QuickBEAM.VM.Runtime.Reference.t(),
          depth: non_neg_integer(),
          continuation:
            QuickBEAM.VM.Runtime.Frame.t() | QuickBEAM.VM.Runtime.Boundary.Iterator.t() | nil
        }
end
