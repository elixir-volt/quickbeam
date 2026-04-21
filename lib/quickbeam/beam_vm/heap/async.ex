defmodule QuickBEAM.BeamVM.Heap.Async do
  @moduledoc false

  def enqueue_microtask(task) do
    queue = Process.get(:qb_microtask_queue, :queue.new())
    Process.put(:qb_microtask_queue, :queue.in(task, queue))
  end

  def dequeue_microtask do
    queue = Process.get(:qb_microtask_queue, :queue.new())

    case :queue.out(queue) do
      {{:value, task}, rest} ->
        Process.put(:qb_microtask_queue, rest)
        task

      {:empty, _} ->
        nil
    end
  end

  def get_promise_waiters(ref), do: Process.get({:qb_promise_waiters, ref}, [])
  def put_promise_waiters(ref, waiters), do: Process.put({:qb_promise_waiters, ref}, waiters)
  def delete_promise_waiters(ref), do: Process.delete({:qb_promise_waiters, ref})
end
