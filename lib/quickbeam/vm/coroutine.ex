defmodule QuickBEAM.VM.Coroutine do
  @moduledoc """
  Captures a detached async frame and its explicit JavaScript caller stack.

  Coroutines remain local to one evaluation process and are resumed by that
  process's FIFO microtask queue.
  """

  @enforce_keys [:frame, :callers, :boundary]
  defstruct [:frame, :callers, :boundary]

  @type t :: %__MODULE__{
          frame: QuickBEAM.VM.Frame.t(),
          callers: [QuickBEAM.VM.Frame.t() | QuickBEAM.VM.NativeFrame.t()],
          boundary: QuickBEAM.VM.AsyncBoundary.t()
        }
end
