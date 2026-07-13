defmodule QuickBEAM.VM.Builtin.Call do
  @moduledoc """
  Carries one builtin invocation through the canonical invocation boundary.

  Handlers receive explicit arguments, receiver, continuation, tail-call mode,
  and owner-local execution state. They must not fetch mutable state elsewhere.
  """

  alias QuickBEAM.VM.Execution

  @enforce_keys [:arguments, :this, :caller, :tail?, :execution]
  defstruct [:arguments, :this, :caller, :tail?, :execution]

  @type t :: %__MODULE__{
          arguments: [term()],
          this: term(),
          caller: term(),
          tail?: boolean(),
          execution: Execution.t()
        }
end
