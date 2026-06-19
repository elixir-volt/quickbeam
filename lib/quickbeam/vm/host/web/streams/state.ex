defmodule QuickBEAM.VM.Host.Web.Streams.State do
  @moduledoc "Heap-backed state helpers for Web stream objects."

  alias QuickBEAM.VM.Heap

  def new(fields \\ %{}) do
    ref = make_ref()
    Heap.put_obj(ref, Map.merge(%{chunks: [], closed: false}, fields))
    ref
  end

  def get(ref), do: Heap.get_obj(ref, %{})
  def put(ref, state), do: Heap.put_obj(ref, state)

  def append_chunk(ref, chunk) do
    state = get(ref)
    chunks = Map.get(state, :chunks, [])
    put(ref, Map.put(state, :chunks, chunks ++ [chunk]))
  end

  def take_chunk(ref) do
    state = get(ref)

    case Map.get(state, :chunks, []) do
      [chunk | rest] ->
        put(ref, Map.put(state, :chunks, rest))
        {:ok, chunk}

      [] ->
        :empty
    end
  end

  def close(ref) do
    ref
    |> get()
    |> Map.put(:closed, true)
    |> then(&put(ref, &1))
  end

  def error(ref, reason) do
    ref
    |> get()
    |> Map.merge(%{closed: true, error: reason})
    |> then(&put(ref, &1))
  end

  def closed?(ref), do: Map.get(get(ref), :closed, false)
  def locked?(ref), do: Map.get(get(ref), :locked, false)

  def set_locked(ref, locked?) do
    ref
    |> get()
    |> Map.put(:locked, locked?)
    |> then(&put(ref, &1))
  end
end
