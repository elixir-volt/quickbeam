defmodule QuickBEAM.VM.Runtime.Boundary.Async do
  @moduledoc """
  Describes the Promise and caller boundary owned by an async invocation.

  The interpreter uses this boundary to settle the async function's result and
  resume, return to, or detach from its caller without using the BEAM stack.
  """

  @enforce_keys [:promise, :depth]
  defstruct [:promise, :caller, :depth, mode: :push]

  @type t :: %__MODULE__{
          promise: QuickBEAM.VM.Runtime.Promise.Reference.t(),
          caller:
            QuickBEAM.VM.Runtime.Boundary.Accessor.t()
            | QuickBEAM.VM.Runtime.Frame.t()
            | QuickBEAM.VM.Runtime.Boundary.ObjectAssign.t()
            | QuickBEAM.VM.Runtime.Frame.Native.t()
            | QuickBEAM.VM.Runtime.Boundary.Reaction.t()
            | QuickBEAM.VM.Runtime.Boundary.PromiseExecutor.t()
            | QuickBEAM.VM.Runtime.Boundary.Thenable.t()
            | QuickBEAM.VM.Runtime.Boundary.ThenGetter.t()
            | nil,
          depth: pos_integer(),
          mode: :push | :return | :reaction | :executor | :thenable | :detached
        }
end
