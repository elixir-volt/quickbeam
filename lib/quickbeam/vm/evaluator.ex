defmodule QuickBEAM.VM.Evaluator do
  @moduledoc false

  alias QuickBEAM.VM.{
    Continuation,
    Coroutine,
    Execution,
    Interpreter,
    Memory,
    Promise,
    PromiseReference,
    Program,
    Reaction
  }

  @spec eval(Program.t(), keyword()) :: Interpreter.result()
  def eval(%Program{} = program, opts \\ []) do
    program
    |> Interpreter.start(opts)
    |> drive()
  end

  defp drive({:ok, %PromiseReference{} = promise, execution}),
    do: await_final_promise(promise, execution)

  defp drive({:suspended, %Continuation{awaiting: :microtask} = continuation}) do
    case :queue.out(continuation.execution.jobs) do
      {{:value, result}, jobs} when elem(result, 0) in [:ok, :error] ->
        continuation = %{continuation | execution: %{continuation.execution | jobs: jobs}}
        then_resume(result, continuation)

      {:empty, _jobs} ->
        {:error, :missing_microtask}
    end
  end

  defp drive({:suspended, %Continuation{awaiting: %PromiseReference{}} = continuation}) do
    await_legacy_promise(continuation)
  end

  defp drive({:suspended, _continuation} = suspended), do: Interpreter.finish(suspended)

  defp drive({status, _value, execution} = result) when status in [:ok, :error] do
    cancel_operations(execution.operations)
    Interpreter.finish(result)
  end

  defp drive({:idle, execution}) do
    cancel_operations(execution.operations)
    {:error, :idle_evaluation}
  end

  defp await_final_promise(%PromiseReference{} = promise, execution) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} ->
        finish_final({:ok, value, execution})

      {:rejected, %QuickBEAM.JSError{} = error} ->
        finish_final({:error, error, execution})

      {:rejected, reason} ->
        finish_final({:error, QuickBEAM.JSError.from_vm(reason, []), execution})

      :pending ->
        drive_event_loop(promise, execution)
    end
  end

  defp drive_event_loop(final_promise, execution) do
    case :queue.out(execution.jobs) do
      {{:value, job}, jobs} ->
        execution = %{execution | jobs: jobs}
        run_job(job, final_promise, execution)

      {:empty, _jobs} when map_size(execution.operations) > 0 ->
        receive_host_reply(final_promise, execution)

      {:empty, _jobs} ->
        finish_final({:error, {:promise_deadlock, final_promise.id}, execution})
    end
  end

  defp run_job({:resume_coroutine, %Coroutine{} = coroutine, result}, final_promise, execution) do
    coroutine
    |> Interpreter.resume_coroutine(result, execution)
    |> continue_final(final_promise)
  end

  defp run_job(
         {:assimilate_thenable, promise, thenable, callable},
         final_promise,
         execution
       ) do
    promise
    |> Interpreter.assimilate_thenable(thenable, callable, execution)
    |> continue_final(final_promise)
  end

  defp run_job({:run_reaction, %Reaction{} = reaction, result}, final_promise, execution) do
    reaction
    |> Interpreter.run_reaction(result, execution)
    |> continue_final(final_promise)
  end

  defp run_job({:aggregate_settle, id, index, result}, final_promise, execution) do
    execution = Promise.settle_aggregate(execution, id, index, result)
    await_final_promise(final_promise, execution)
  end

  defp run_job({:settle_assimilated, promise, result}, final_promise, execution) do
    execution = Promise.settle_assimilated(execution, promise, result)
    await_final_promise(final_promise, execution)
  end

  defp run_job({:settle_promise, promise, result}, final_promise, execution) do
    execution = Promise.settle(execution, promise, result)
    await_final_promise(final_promise, execution)
  end

  defp continue_final({:idle, execution}, final_promise),
    do: await_final_promise(final_promise, execution)

  defp continue_final({:ok, _value, execution}, final_promise),
    do: await_final_promise(final_promise, execution)

  defp continue_final({:error, _reason, _execution} = error, _final_promise),
    do: finish_final(error)

  defp continue_final({:suspended, continuation}, _final_promise),
    do: drive({:suspended, continuation})

  defp receive_host_reply(final_promise, execution) do
    receive do
      {:quickbeam_vm_host_reply, operation, result} ->
        case settle_host_reply(execution, operation, result) do
          {:ok, execution} -> await_final_promise(final_promise, execution)
          :stale -> receive_host_reply(final_promise, execution)
        end
    end
  end

  defp await_legacy_promise(%Continuation{} = continuation) do
    receive do
      {:quickbeam_vm_host_reply, operation, result} ->
        case settle_host_reply(continuation.execution, operation, result) do
          {:ok, execution} ->
            continuation = %{continuation | execution: execution}

            if Promise.state(execution, continuation.awaiting) == :pending do
              await_legacy_promise(continuation)
            else
              result = settled_result(continuation.awaiting, execution)
              execution = %{execution | jobs: :queue.in(result, execution.jobs)}
              drive({:suspended, %{continuation | execution: execution, awaiting: :microtask}})
            end

          :stale ->
            await_legacy_promise(continuation)
        end
    end
  end

  defp settle_host_reply(execution, operation, result) do
    case Map.pop(execution.operations, operation) do
      {nil, _operations} ->
        :stale

      {{promise, _pid}, operations} ->
        execution = %{execution | operations: operations}
        execution = charge_host_result(execution, result)
        {:ok, Promise.settle(execution, promise, result)}
    end
  end

  defp charge_host_result(execution, {:ok, value}),
    do: Memory.charge(execution, Memory.estimate(value))

  defp charge_host_result(execution, {:error, reason}),
    do: Memory.charge(execution, Memory.estimate(reason))

  defp settled_result(promise, execution) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} -> {:ok, value}
      {:rejected, reason} -> {:error, reason}
    end
  end

  defp then_resume(result, continuation) do
    continuation
    |> Interpreter.resume_raw(result)
    |> drive()
  end

  defp finish_final({status, _value, %Execution{} = execution} = result)
       when status in [:ok, :error] do
    cancel_operations(execution.operations)
    Interpreter.finish(result)
  end

  defp cancel_operations(operations) do
    Enum.each(operations, fn {_operation, {_promise, pid}} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end
end
