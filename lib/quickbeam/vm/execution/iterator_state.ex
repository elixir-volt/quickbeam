defmodule QuickBEAM.VM.Execution.IteratorState do
  @moduledoc "Process-local mutable cursors for iterator objects."

  def new(initial) do
    ref = make_ref()
    Process.put(ref, initial)
    ref
  end

  def get(ref, default), do: Process.get(ref, default)

  def put(ref, value) do
    Process.put(ref, value)
    value
  end
end
