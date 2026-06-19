defmodule QuickBEAM.VM.Execution.IteratorHelperState do
  @moduledoc "Heap-backed state updates for Iterator helper objects."

  alias QuickBEAM.VM.Heap

  def new(initial) when is_map(initial) do
    ref = make_ref()
    replace(ref, initial)
    ref
  end

  def get(ref, default \\ %{}), do: Heap.get_obj(ref, default)

  def replace(ref, state) when is_map(state) do
    Heap.put_obj(ref, state)
    state
  end

  def put(ref, state, key, value) when is_map(state) do
    replace(ref, Map.put(state, key, value))
  end

  def merge(ref, state, changes) when is_map(state) and is_map(changes) do
    replace(ref, Map.merge(state, changes))
  end

  def mark_done(ref), do: replace(ref, %{"kind" => :done, "executing" => false})
end
