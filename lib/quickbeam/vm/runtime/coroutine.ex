defmodule QuickBEAM.VM.Runtime.Coroutine do
  @moduledoc """
  Captures a detached async frame and its explicit JavaScript caller stack.

  Coroutines remain local to one evaluation process and are resumed by that
  process's FIFO microtask queue.
  """

  @enforce_keys [:frame, :callers, :boundary]
  defstruct [:frame, :callers, :boundary]

  @type t :: %__MODULE__{
          frame: QuickBEAM.VM.Runtime.Frame.t(),
          callers: [QuickBEAM.VM.Runtime.Frame.t() | QuickBEAM.VM.Runtime.Frame.Native.t()],
          boundary: QuickBEAM.VM.Runtime.Boundary.Async.t()
        }
end
