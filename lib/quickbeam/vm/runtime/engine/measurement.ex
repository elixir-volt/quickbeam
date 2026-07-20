defmodule QuickBEAM.VM.Runtime.Engine.Measurement do
  @moduledoc """
  Carries interpreter and release-quarantined compiler observations for internal
  tests and benchmarks.
  """

  @enforce_keys [:result, :wall_time_us]
  defstruct [
    :result,
    :wall_time_us,
    :steps,
    :logical_memory_bytes,
    :compiler_counters,
    :compiler_regions,
    :process_memory_bytes,
    :reductions
  ]

  @type t :: %__MODULE__{
          result: {:ok, term()} | {:error, term()},
          wall_time_us: non_neg_integer(),
          steps: non_neg_integer() | nil,
          logical_memory_bytes: non_neg_integer() | nil,
          compiler_counters: map() | nil,
          compiler_regions: map() | nil,
          process_memory_bytes: non_neg_integer() | nil,
          reductions: non_neg_integer() | nil
        }
end
