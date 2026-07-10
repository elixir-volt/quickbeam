defmodule QuickBEAM.VM.AsyncBoundary do
  @moduledoc false

  @enforce_keys [:promise, :depth]
  defstruct [:promise, :caller, :depth, mode: :push]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          caller:
            QuickBEAM.VM.Frame.t()
            | QuickBEAM.VM.NativeFrame.t()
            | QuickBEAM.VM.ReactionBoundary.t()
            | QuickBEAM.VM.PromiseExecutorBoundary.t()
            | QuickBEAM.VM.ThenableBoundary.t()
            | nil,
          depth: pos_integer(),
          mode: :push | :return | :reaction | :executor | :thenable | :detached
        }
end
