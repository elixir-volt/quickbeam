defmodule QuickBEAM.VM.Fuzz.Summary do
  @moduledoc "Aggregated result of a bounded mutation-fuzzing run."

  @enforce_keys [:domain, :seed, :iterations, :counts, :operation_counts, :findings]
  defstruct [:domain, :seed, :iterations, :counts, :operation_counts, :findings]

  @type t :: %__MODULE__{
          domain: :bytecode | :program,
          seed: non_neg_integer(),
          iterations: non_neg_integer(),
          counts: %{optional(atom()) => non_neg_integer()},
          operation_counts: %{optional(atom()) => non_neg_integer()},
          findings: [QuickBEAM.VM.Fuzz.Finding.t()]
        }
end
