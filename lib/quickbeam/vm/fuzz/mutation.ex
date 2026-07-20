defmodule QuickBEAM.VM.Fuzz.Mutation do
  @moduledoc """
  Describes one reproducible decoder or verifier mutation.

  The original corpus value is intentionally not retained. Replaying the same
  corpus entry with `seed` and `iteration` reconstructs `value` exactly.
  """

  @enforce_keys [:domain, :corpus, :seed, :iteration, :operation, :value]
  defstruct [:domain, :corpus, :seed, :iteration, :operation, :value, details: %{}]

  @type t :: %__MODULE__{
          domain: :bytecode | :program,
          corpus: String.t(),
          seed: non_neg_integer(),
          iteration: non_neg_integer(),
          operation: atom(),
          value: binary() | QuickBEAM.VM.Program.t(),
          details: map()
        }
end
