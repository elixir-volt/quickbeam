defmodule QuickBEAM.VM.Evaluator do
  @moduledoc """
  Drives an interpreter evaluation and its owner-local event loop.

  The evaluator drains microtasks, correlates asynchronous host replies, resumes
  coroutines, and waits for the final Promise without polling.
  """

  alias QuickBEAM.VM.{
    Async,
    Continuation,
    Coroutine,
    Exceptions,
    Execution,
    Interpreter,
    Program,
    Promise,
    PromiseReference,
    Reaction
  }

  @spec eval(Program.t(), keyword()) :: Interpreter.result()
  def eval(%Program{} = program, opts \\ []) do
    program
    |> Interpreter.start(opts)
    |> drive()
  end

  @doc "Evaluates a program and returns deterministic counters plus endpoint process observations."
  @spec eval_with_metrics(Program.t(), keyword()) :: {Interpreter.result(), map() | nil}
  def eval_with_metrics(%Program{} = program, opts \\ []) do
    ref = make_ref()
    result = eval(program, Keyword.put(opts, :measurement_target, {self(), ref}))

    receive do
      {:quickbeam_vm_measurement, ^ref, metrics} -> {result, metrics}
    after
      0 -> {result, nil}
    end
  end

  defp drive({:ok, %PromiseReference{} = promise, execution}),
    do: await_final_promise(promise, execution)

  defp drive({:suspended, %Continuation{awaiting: :microtask} = continuation}) do
    case :queue.out(continuation.execution.jobs) do
      {{:value, result}, jobs} when elem(result, 0) in [:ok, :error] ->
        continuation = %{continuation | execution: %{continuation.execution | jobs: jobs}}
        then_resume(result, continuation)

      {:empty, _jobs} ->
        finish_final({:error, :missing_microtask, continuation.execution})
    end
  end

  defp drive({:suspended, %Continuation{awaiting: %PromiseReference{}} = continuation}) do
    await_legacy_promise(continuation)
  end

  defp drive({:suspended, %Continuation{} = continuation} = suspended),
    do: finish_suspended(suspended, continuation.execution)

  defp drive({status, _value, _execution} = result) when status in [:ok, :error],
    do: finish_final(result)

  defp drive({:idle, execution}),
    do: finish_final({:error, :idle_evaluation, execution})

  defp await_final_promise(%PromiseReference{} = promise, execution) do
    if :queue.is_empty(execution.sync_jobs) do
      await_settled_promise(promise, execution)
    else
      execution
      |> Interpreter.run_synchronous_job()
      |> continue_final(promise)
    end
  end

  defp await_settled_promise(promise, execution) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} ->
        finish_final({:ok, value, execution})

      {:rejected, %QuickBEAM.JSError{} = error} ->
        finish_final({:error, error, execution})

      {:rejected, reason} ->
        error = Exceptions.to_js_error(reason, execution, [])
        finish_final({:error, error, execution})

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

  defp run_job({:read_thenable, promise, thenable, getter}, final_promise, execution) do
    promise
    |> Interpreter.read_thenable(thenable, getter, execution)
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
        case Async.settle_host_reply(execution, operation, result) do
          {:ok, execution} -> await_final_promise(final_promise, execution)
          :stale -> receive_host_reply(final_promise, execution)
        end
    end
  end

  defp await_legacy_promise(%Continuation{} = continuation) do
    receive do
      {:quickbeam_vm_host_reply, operation, result} ->
        case Async.settle_host_reply(continuation.execution, operation, result) do
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
    Async.cancel_operations(execution)
    finished = Interpreter.finish(result)
    report_measurement(execution)
    finished
  end

  defp finish_suspended(result, execution) do
    finished = Interpreter.finish(result)
    report_measurement(execution)
    finished
  end

  defp report_measurement(%Execution{measurement_target: nil}), do: :ok

  defp report_measurement(%Execution{measurement_target: {pid, ref}} = execution) do
    process_memory = process_stat(:memory)
    reductions = process_stat(:reductions)

    send(
      pid,
      {:quickbeam_vm_measurement, ref,
       %{
         steps: execution.step_limit - execution.remaining_steps,
         logical_memory_bytes: execution.memory_used,
         process_memory_bytes: process_memory,
         reductions: reductions
       }}
    )

    :ok
  end

  defp process_stat(key) do
    case Process.info(self(), key) do
      {^key, value} -> value
      nil -> nil
    end
  end
end
