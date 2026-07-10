defmodule QuickBEAM.VM.Continuation do
  @moduledoc false

  @enforce_keys [:frame, :execution]
  defstruct [:frame, :execution, :awaiting]

  @type t :: %__MODULE__{
          frame: QuickBEAM.VM.Frame.t(),
          execution: QuickBEAM.VM.Execution.t(),
          awaiting: QuickBEAM.VM.PromiseReference.t() | term() | nil
        }
end
