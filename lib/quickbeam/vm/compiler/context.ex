defmodule QuickBEAM.VM.Compiler.Context do
  @moduledoc """
  Carries immutable compiler identity through one owner-local evaluation.

  The shared program remains immutable. Mutable frames, heaps, jobs, and
  continuations stay in the owning `%QuickBEAM.VM.Execution{}`.
  """

  alias QuickBEAM.VM.Compiler.Counters

  @enforce_keys [:pool, :program]
  defstruct [
    :pool,
    :program,
    artifact_namespace: nil,
    decisions: %{},
    max_decisions: 256,
    min_nested_instructions: 32,
    profile: :pure_v1,
    counters: nil
  ]

  @type t :: %__MODULE__{
          pool: QuickBEAM.VM.Compiler.ModulePool.server(),
          program: QuickBEAM.VM.Program.t(),
          artifact_namespace: binary() | nil,
          decisions: %{
            optional(non_neg_integer()) =>
              :skip | {:cached, binary()} | {:compile, binary(), term()}
          },
          max_decisions: pos_integer(),
          min_nested_instructions: non_neg_integer(),
          profile: :pure_v1 | :scalar_v1,
          counters: Counters.t() | nil
        }
end
