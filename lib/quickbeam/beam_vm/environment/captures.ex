defmodule QuickBEAM.BeamVM.Environment.Captures do
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  def ensure({:cell, _} = cell, _val), do: cell

  def ensure(_cell, val) do
    ref = make_ref()
    Heap.put_cell(ref, val)
    {:cell, ref}
  end

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

  def sync({:cell, ref}, val) do
    Heap.put_cell(ref, val)
    :ok
  end

  def sync(_, _), do: :ok
end
