defmodule QuickBEAM.VM.Host.Web.ConsoleAPI.State do
  @moduledoc "Process-local state for console timers and counters."

  @timer_key :qb_console_timers
  @count_key :qb_console_counts

  def put_timer(label, started_at) do
    Process.put(@timer_key, Map.put(timers(), label, started_at))
    :ok
  end

  def pop_timer(label) do
    timers = timers()
    value = Map.get(timers, label)
    Process.put(@timer_key, Map.delete(timers, label))
    value
  end

  def timer(label), do: Map.get(timers(), label)

  def increment_count(label) do
    n = Map.get(counts(), label, 0) + 1
    Process.put(@count_key, Map.put(counts(), label, n))
    n
  end

  def reset_count(label) do
    counts = counts()

    if Map.has_key?(counts, label) do
      Process.put(@count_key, Map.put(counts, label, 0))
      true
    else
      false
    end
  end

  defp timers, do: Process.get(@timer_key, %{})
  defp counts, do: Process.get(@count_key, %{})
end
