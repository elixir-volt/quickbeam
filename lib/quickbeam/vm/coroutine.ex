defmodule QuickBEAM.VM.Coroutine do
  @moduledoc false

  @enforce_keys [:frame, :callers, :boundary]
  defstruct [:frame, :callers, :boundary]

  @type t :: %__MODULE__{
          frame: QuickBEAM.VM.Frame.t(),
          callers: [QuickBEAM.VM.Frame.t() | QuickBEAM.VM.NativeFrame.t()],
          boundary: QuickBEAM.VM.AsyncBoundary.t()
        }
end
