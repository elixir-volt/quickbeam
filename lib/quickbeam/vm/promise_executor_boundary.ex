defmodule QuickBEAM.VM.PromiseExecutorBoundary do
  @moduledoc """
  Records the caller waiting for synchronous Promise executor completion.

  Executor return values are ignored; this boundary returns the constructed
  Promise and converts a synchronous executor throw into rejection.
  """

  @enforce_keys [:promise, :caller, :depth]
  defstruct [:promise, :caller, :depth, tail?: false]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          caller: QuickBEAM.VM.Frame.t() | QuickBEAM.VM.NativeFrame.t(),
          depth: non_neg_integer(),
          tail?: boolean()
        }
end
