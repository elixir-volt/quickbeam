defmodule QuickBEAM.VM.Environment.Captures do
  @moduledoc "Helpers for boxing, closing, and synchronizing captured lexical variables."

  alias QuickBEAM.VM.Heap

  @doc "Ensures a captured value is represented by a heap cell."
  def ensure({:cell, _} = cell, _val), do: cell

  def ensure(_cell, val) do
    ref = make_ref()
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  @doc "Closes over a captured value by copying it into a fresh heap cell."
  def close({:cell, ref}, val) do
    current = Heap.get_cell(ref)
    next_val = if current == :undefined, do: val, else: current
    new_ref = make_ref()
    Heap.put_cell(new_ref, next_val)
    {:cell, new_ref}
  end

  def close(_cell, val) do
    ref = make_ref()
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

  @doc "Synchronizes a captured cell with a new local value."
  def sync({:cell, ref}, val) do
    Heap.put_cell(ref, val)
    :ok
  end

  def sync(_, _), do: :ok
end
