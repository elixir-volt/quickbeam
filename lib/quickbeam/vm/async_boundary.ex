defmodule QuickBEAM.VM.AsyncBoundary do
  @moduledoc """
  Describes the Promise and caller boundary owned by an async invocation.

  The interpreter uses this boundary to settle the async function's result and
  resume, return to, or detach from its caller without using the BEAM stack.
  """

  @enforce_keys [:promise, :depth]
  defstruct [:promise, :caller, :depth, mode: :push]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.PromiseReference.t(),
          caller:
            QuickBEAM.VM.AccessorBoundary.t()
            | QuickBEAM.VM.Frame.t()
            | QuickBEAM.VM.ObjectAssignBoundary.t()
            | QuickBEAM.VM.NativeFrame.t()
            | QuickBEAM.VM.ReactionBoundary.t()
            | QuickBEAM.VM.PromiseExecutorBoundary.t()
            | QuickBEAM.VM.ThenableBoundary.t()
            | QuickBEAM.VM.ThenGetterBoundary.t()
            | nil,
          depth: pos_integer(),
          mode: :push | :return | :reaction | :executor | :thenable | :detached
        }
end
