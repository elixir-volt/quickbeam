defmodule QuickBEAM.VM.Execution.IteratorState do
  @moduledoc "Process-local mutable cursors for iterator objects."

  def new(initial) do
    ref = make_ref()
    Process.put(key(ref), initial)
    ref
  end

  def get(ref, default), do: Process.get(key(ref), default)

  def put(ref, value) do
    Process.put(key(ref), value)
    value
  end

  defp key(ref), do: {:qb_iterator_state, ref}
end
