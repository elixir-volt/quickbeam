defmodule QuickBEAM.VM.Compiler.RegionProbe do
  @moduledoc """
  Samples bounded owner-local instruction windows for compiler diagnostics.

  The probe is opt-in, uses OTP `:counters` for its sampling clock, and retains
  at most 64 integer `{function_id, entry_pc}` keys with the Space-Saving
  heavy-hitter algorithm. It never creates atoms or shared mutable state and is
  not enabled by ordinary evaluation or standard measurements.
  """

  alias QuickBEAM.VM.{Execution, Frame}

  @sample_interval 16
  @window_size 64
  @max_entries 64

  @enforce_keys [:owner, :sample_counter]
  defstruct [:owner, :sample_counter, entries: %{}]

  @type entry :: %{samples: pos_integer(), error: non_neg_integer()}
  @type t :: %__MODULE__{
          owner: pid(),
          sample_counter: term(),
          entries: %{{non_neg_integer(), non_neg_integer()} => entry()}
        }

  @doc "Creates one fixed-capacity probe owned by the current evaluation process."
  @spec new() :: t()
  def new,
    do: %__MODULE__{owner: self(), sample_counter: :counters.new(1, [])}

  @doc "Samples one canonical interpreted frame without changing VM semantics."
  @spec observe(Execution.t(), Frame.t()) :: Execution.t()
  def observe(
        %Execution{compiler_context: %{region_probe: %__MODULE__{owner: owner} = probe} = context} =
          execution,
        %Frame{function: %{id: function_id}, pc: pc}
      )
      when owner == self() and is_integer(function_id) and function_id >= 0 and is_integer(pc) and
             pc >= 0 do
    :counters.add(probe.sample_counter, 1, 1)
    count = :counters.get(probe.sample_counter, 1)

    if rem(count, @sample_interval) == 0 do
      key = {function_id, div(pc, @window_size) * @window_size}
      probe = %{probe | entries: increment(probe.entries, key)}
      %{execution | compiler_context: %{context | region_probe: probe}}
    else
      execution
    end
  end

  def observe(%Execution{} = execution, %Frame{}), do: execution

  @doc "Returns bounded heavy hitters and sampling metadata at evaluation completion."
  @spec snapshot(Execution.t()) :: map() | nil
  def snapshot(%Execution{
        compiler_context: %{region_probe: %__MODULE__{owner: owner} = probe}
      })
      when owner == self() do
    regions =
      probe.entries
      |> Enum.map(fn {{function_id, entry_pc}, entry} ->
        %{
          function_id: function_id,
          entry_pc: entry_pc,
          samples: entry.samples,
          error: entry.error
        }
      end)
      |> Enum.sort_by(&{-&1.samples, &1.function_id, &1.entry_pc})

    %{
      sample_interval: @sample_interval,
      window_size: @window_size,
      total_samples: div(:counters.get(probe.sample_counter, 1), @sample_interval),
      regions: regions
    }
  end

  def snapshot(%Execution{}), do: nil

  defp increment(entries, key) do
    case Map.fetch(entries, key) do
      {:ok, entry} ->
        Map.put(entries, key, %{entry | samples: entry.samples + 1})

      :error when map_size(entries) < @max_entries ->
        Map.put(entries, key, %{samples: 1, error: 0})

      :error ->
        {victim, entry} =
          Enum.min_by(entries, fn {candidate, value} -> {value.samples, candidate} end)

        entries
        |> Map.delete(victim)
        |> Map.put(key, %{samples: entry.samples + 1, error: entry.samples})
    end
  end
end
