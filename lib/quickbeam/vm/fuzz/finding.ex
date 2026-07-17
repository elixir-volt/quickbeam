defmodule QuickBEAM.VM.Fuzz.Finding do
  @moduledoc "A reproducible crash, timeout, nondeterminism, or verifier acceptance."

  @enforce_keys [:mutation, :outcome]
  defstruct [:mutation, :outcome]

  @type t :: %__MODULE__{
          mutation: QuickBEAM.VM.Fuzz.Mutation.t(),
          outcome: term()
        }
end
