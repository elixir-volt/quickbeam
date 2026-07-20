defmodule QuickBEAM.VM.Compiler.Instrumentation do
  @moduledoc """
  Adapts compiler counters and region probes to the runtime's optional dynamic
  optimization-hook contract.
  """

  alias QuickBEAM.VM.Compiler.Counter
  alias QuickBEAM.VM.Compiler.Region.Probe
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.State

  @doc "Increments a fixed compiler event."
  @spec increment(State.t(), atom()) :: State.t()
  defdelegate increment(execution, event), to: Counter

  @doc "Records one interpreted opcode for compiler coverage."
  @spec interpreted_opcode(State.t(), non_neg_integer()) :: State.t()
  defdelegate interpreted_opcode(execution, opcode), to: Counter

  @doc "Samples one canonical interpreted frame for bounded region diagnostics."
  @spec observe(State.t(), Frame.t()) :: State.t()
  defdelegate observe(execution, frame), to: Probe

  @doc "Returns compiler counter and region snapshots at evaluation completion."
  @spec snapshot(State.t()) :: map()
  def snapshot(%State{} = execution) do
    %{
      compiler_counters: Counter.snapshot(execution),
      compiler_regions: Probe.snapshot(execution)
    }
  end
end
