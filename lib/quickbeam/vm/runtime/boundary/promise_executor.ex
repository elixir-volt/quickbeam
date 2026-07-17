defmodule QuickBEAM.VM.Runtime.Boundary.PromiseExecutor do
  @moduledoc """
  Records the caller waiting for synchronous Promise executor completion.

  Executor return values are ignored; this boundary returns the constructed
  Promise and converts a synchronous executor throw into rejection.
  """

  @enforce_keys [:promise, :caller, :depth]
  defstruct [:promise, :caller, :depth, tail?: false]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.Runtime.Promise.Reference.t(),
          caller: QuickBEAM.VM.Runtime.Frame.t() | QuickBEAM.VM.Runtime.Frame.Native.t(),
          depth: non_neg_integer(),
          tail?: boolean()
        }
end
