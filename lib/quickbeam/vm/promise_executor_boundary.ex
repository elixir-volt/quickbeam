defmodule QuickBEAM.VM.PromiseExecutorBoundary do
  @moduledoc false

  @enforce_keys [:promise, :caller, :depth]
  defstruct [:promise, :caller, :depth, tail?: false]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          caller: QuickBEAM.VM.Frame.t() | QuickBEAM.VM.NativeFrame.t(),
          depth: non_neg_integer(),
          tail?: boolean()
        }
end
