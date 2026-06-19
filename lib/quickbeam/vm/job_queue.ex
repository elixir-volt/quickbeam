defmodule QuickBEAM.VM.JobQueue do
  @moduledoc "ECMAScript job queue helpers backed by the VM heap microtask queue."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.Promise

  @doc "Queues a promise reaction job."
  def enqueue_promise_reaction(child_ref, callback, value) do
    Heap.enqueue_microtask({:resolve, child_ref, callback, value})
  end

  @doc "Runs queued microtasks until the queue is empty."
  def drain_microtasks do
    case Heap.dequeue_microtask() do
      nil ->
        :ok

      {:resolve, nil, callback, value} ->
        invoke_fire_and_forget(callback, value)
        drain_microtasks()

      {:resolve, child_ref, callback, value} ->
        callback
        |> invoke_reaction(value)
        |> Promise.resolve_reaction_result(child_ref)

        drain_microtasks()
    end
  end

  defp invoke_fire_and_forget(callback, value) do
    try do
      Interpreter.invoke_callback(callback, [value])
    catch
      {:js_throw, _} -> :ok
    end
  end

  defp invoke_reaction(callback, value) do
    try do
      Interpreter.invoke_callback(callback, [value])
    catch
      {:js_throw, err} -> {:rejected, err}
    end
  end
end
