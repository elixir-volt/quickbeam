defmodule QuickBEAM.VM.Measurement do
  @moduledoc """
  Resource and timing observations for one isolated VM evaluation.

  `steps` and `logical_memory_bytes` come from deterministic VM accounting.
  `compiler_counters` snapshots fixed-size owner-local OTP `:counters` when the
  compiler engine is selected. Its compilation/cache decision fields
  are lifecycle observations. `process_memory_bytes` and `reductions` are
  endpoint observations from the evaluation process, not sampled peaks. `wall_time_us` includes isolated
  process startup, host waits, result conversion, and reply delivery.
  """

  @enforce_keys [:result, :wall_time_us]
  defstruct [
    :result,
    :wall_time_us,
    :steps,
    :logical_memory_bytes,
    :compiler_counters,
    :process_memory_bytes,
    :reductions
  ]

  @type t :: %__MODULE__{
          result: {:ok, term()} | {:error, term()},
          wall_time_us: non_neg_integer(),
          steps: non_neg_integer() | nil,
          logical_memory_bytes: non_neg_integer() | nil,
          compiler_counters: map() | nil,
          process_memory_bytes: non_neg_integer() | nil,
          reductions: non_neg_integer() | nil
        }
end
