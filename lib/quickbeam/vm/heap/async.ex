defmodule QuickBEAM.VM.Heap.Async do
  @moduledoc "Process-local queues for microtasks and promise waiters."

  @doc "Adds a microtask to the process-local JavaScript microtask queue."
  def enqueue_microtask(task) do
    queue = Process.get(:qb_microtask_queue, :queue.new())
    Process.put(:qb_microtask_queue, :queue.in(task, queue))
  end

  @doc "Returns whether the JavaScript microtask queue is empty."
  def microtasks_empty? do
    case Process.get(:qb_microtask_queue) do
      nil -> true
      queue -> :queue.is_empty(queue)
    end
  end

  @doc "Removes and returns the next queued microtask, or `nil` when the queue is empty."
  def dequeue_microtask do
    case Process.get(:qb_microtask_queue) do
      nil ->
        nil

      queue ->
        case :queue.out(queue) do
          {{:value, task}, rest} ->
            Process.put(:qb_microtask_queue, rest)
            task

          {:empty, _} ->
            nil
        end
    end
  end

  @doc "Returns callbacks waiting for the promise identified by `ref`."
  def get_promise_waiters(ref), do: Process.get({:qb_promise_waiters, ref}, [])
  @doc "Stores callbacks waiting for the promise identified by `ref`."
  def put_promise_waiters(ref, waiters), do: Process.put({:qb_promise_waiters, ref}, waiters)
  @doc "Deletes waiter state for the promise identified by `ref`."
  def delete_promise_waiters(ref), do: Process.delete({:qb_promise_waiters, ref})
end
