defmodule QuickBEAM.VM.Compiler.Context do
  @moduledoc """
  Carries immutable compiler identity through one owner-local evaluation.

  The shared program remains immutable. Mutable frames, heaps, jobs, and
  continuations stay in the owning `%QuickBEAM.VM.Runtime.State{}`.
  """

  alias QuickBEAM.VM.Compiler.Counter
  alias QuickBEAM.VM.Compiler.Region.Probe

  @enforce_keys [:pool, :program]
  defstruct [
    :pool,
    :program,
    artifact_namespace: nil,
    decisions: %{},
    max_decisions: 256,
    min_nested_instructions: 32,
    profile: :pure_v1,
    counters: nil,
    region_probe: nil,
    regions: false
  ]

  @type t :: %__MODULE__{
          pool: QuickBEAM.VM.Compiler.Pool.server(),
          program: QuickBEAM.VM.Program.t(),
          artifact_namespace: binary() | nil,
          decisions: %{
            optional(non_neg_integer() | {:region, non_neg_integer(), non_neg_integer()}) =>
              :skip | {:cached, binary()} | {:compile, binary(), term()}
          },
          max_decisions: pos_integer(),
          min_nested_instructions: non_neg_integer(),
          profile: :pure_v1 | :scalar_v1,
          counters: Counter.t() | nil,
          region_probe: Probe.t() | nil,
          regions: boolean()
        }
end
