defmodule QuickBEAM.VM.Runtime.Continuation do
  @moduledoc "Captures a legacy suspended frame and its owning execution state."

  @enforce_keys [:frame, :execution]
  defstruct [:frame, :execution, :awaiting]

  @type t :: %__MODULE__{
          frame: QuickBEAM.VM.Runtime.Frame.t(),
          execution: QuickBEAM.VM.Runtime.State.t(),
          awaiting: QuickBEAM.VM.Runtime.Promise.Reference.t() | term() | nil
        }
end
