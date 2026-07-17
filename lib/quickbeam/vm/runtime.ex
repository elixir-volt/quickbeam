defmodule QuickBEAM.VM.Runtime do
  @moduledoc """
  Drives an interpreter evaluation and its owner-local event loop.

  The evaluator drains microtasks, correlates asynchronous host replies, resumes
  coroutines, and waits for the final Promise without polling.
  """

  alias QuickBEAM.VM.Program
  alias QuickBEAM.VM.Runtime.Async
  alias QuickBEAM.VM.Runtime.Continuation
  alias QuickBEAM.VM.Runtime.Coroutine
  alias QuickBEAM.VM.Runtime.Exception
  alias QuickBEAM.VM.Runtime.Interpreter
  alias QuickBEAM.VM.Runtime.Optimization
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.Promise.Reaction
  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference
  alias QuickBEAM.VM.Runtime.State

  @doc "Evaluates a verified program and drains its owner-local event loop."
  @spec eval(Program.t(), keyword()) :: Interpreter.result()
  def eval(%Program{} = program, opts \\ []) do
    program
    |> Interpreter.start(opts)
    |> drive()
  end

  @doc "Calls a named global after initialization and drains the owner-local event loop."
  @spec call(Program.t(), String.t(), [term()], keyword()) :: Interpreter.result()
  def call(%Program{} = program, name, arguments \\ [], opts \\ []) do
    finish_initialization = fn
      {:ok, _value, execution} ->
        program
        |> Interpreter.invoke_global(name, arguments, execution)
        |> drive()

      result ->
        finish_final(result)
    end

    program
    |> Interpreter.start(opts)
    |> drive_with(finish_initialization)
  end

  @doc "Evaluates a program and returns deterministic counters plus endpoint process observations."
  @spec eval_with_metrics(Program.t(), keyword()) :: {Interpreter.result(), map() | nil}
  def eval_with_metrics(%Program{} = program, opts \\ []) do
    measured(fn measured_opts -> eval(program, measured_opts) end, opts)
  end

  @doc "Calls a global and returns deterministic counters plus endpoint process observations."
  @spec call_with_metrics(Program.t(), String.t(), [term()], keyword()) ::
          {Interpreter.result(), map() | nil}
  def call_with_metrics(%Program{} = program, name, arguments \\ [], opts \\ []) do
    measured(fn measured_opts -> call(program, name, arguments, measured_opts) end, opts)
  end

  @doc "Drives a raw interpreter or compiler machine result through the owner-local event loop."
  @spec drive(term()) :: Interpreter.result()
  def drive(result), do: drive_with(result, &finish_final/1)

  defp drive_with({:ok, %PromiseReference{} = promise, execution}, finish),
    do: await_final_promise(promise, execution, finish)

  defp drive_with({:suspended, %Continuation{awaiting: :microtask} = continuation}, finish) do
    case :queue.out(continuation.execution.jobs) do
      {{:value, result}, jobs} when elem(result, 0) in [:ok, :error] ->
        continuation = %{continuation | execution: %{continuation.execution | jobs: jobs}}
        then_resume(result, continuation, finish)

      {:empty, _jobs} ->
        finish.({:error, :missing_microtask, continuation.execution})
    end
  end

  defp drive_with(
         {:suspended, %Continuation{awaiting: %PromiseReference{}} = continuation},
         finish
       ) do
    await_legacy_promise(continuation, finish)
  end

  defp drive_with({:suspended, %Continuation{} = continuation} = suspended, _finish),
    do: finish_suspended(suspended, continuation.execution)

  defp drive_with({status, _value, _execution} = result, finish) when status in [:ok, :error],
    do: finish.(result)

  defp drive_with({:idle, execution}, finish),
    do: finish.({:error, :idle_evaluation, execution})

  defp await_final_promise(%PromiseReference{} = promise, execution, finish) do
    if :queue.is_empty(execution.sync_jobs) do
      await_settled_promise(promise, execution, finish)
    else
      execution
      |> Interpreter.run_synchronous_job()
      |> continue_final(promise, finish)
    end
  end

  defp await_settled_promise(promise, execution, finish) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} ->
        finish.({:ok, value, execution})

      {:rejected, %QuickBEAM.JSError{} = error} ->
        finish.({:error, error, execution})

      {:rejected, reason} ->
        error = Exception.to_js_error(reason, execution, [])
        finish.({:error, error, execution})

      :pending ->
        drive_event_loop(promise, execution, finish)
    end
  end

  defp drive_event_loop(final_promise, execution, finish) do
    case :queue.out(execution.jobs) do
      {{:value, job}, jobs} ->
        execution = %{execution | jobs: jobs}
        run_job(job, final_promise, execution, finish)

      {:empty, _jobs} when map_size(execution.operations) > 0 ->
        receive_host_reply(final_promise, execution, finish)

      {:empty, _jobs} ->
        finish.({:error, {:promise_deadlock, final_promise.id}, execution})
    end
  end

  defp run_job(
         {:resume_coroutine, %Coroutine{} = coroutine, result},
         final_promise,
         execution,
         finish
       ) do
    coroutine
    |> Interpreter.resume_coroutine(result, execution)
    |> continue_final(final_promise, finish)
  end

  defp run_job({:read_thenable, promise, thenable, getter}, final_promise, execution, finish) do
    promise
    |> Interpreter.read_thenable(thenable, getter, execution)
    |> continue_final(final_promise, finish)
  end

  defp run_job(
         {:assimilate_thenable, promise, thenable, callable},
         final_promise,
         execution,
         finish
       ) do
    promise
    |> Interpreter.assimilate_thenable(thenable, callable, execution)
    |> continue_final(final_promise, finish)
  end

  defp run_job(
         {:run_reaction, %Reaction{} = reaction, result},
         final_promise,
         execution,
         finish
       ) do
    reaction
    |> Interpreter.run_reaction(result, execution)
    |> continue_final(final_promise, finish)
  end

  defp run_job({:aggregate_settle, id, index, result}, final_promise, execution, finish) do
    execution = Promise.settle_aggregate(execution, id, index, result)
    await_final_promise(final_promise, execution, finish)
  end

  defp run_job({:settle_assimilated, promise, result}, final_promise, execution, finish) do
    execution = Promise.settle_assimilated(execution, promise, result)
    await_final_promise(final_promise, execution, finish)
  end

  defp run_job({:settle_promise, promise, result}, final_promise, execution, finish) do
    execution = Promise.settle(execution, promise, result)
    await_final_promise(final_promise, execution, finish)
  end

  defp continue_final({:idle, execution}, final_promise, finish),
    do: await_final_promise(final_promise, execution, finish)

  defp continue_final({:ok, _value, execution}, final_promise, finish),
    do: await_final_promise(final_promise, execution, finish)

  defp continue_final({:error, _reason, _execution} = error, _final_promise, finish),
    do: finish.(error)

  defp continue_final({:suspended, continuation}, _final_promise, finish),
    do: drive_with({:suspended, continuation}, finish)

  defp receive_host_reply(final_promise, execution, finish) do
    receive do
      {:quickbeam_vm_host_reply, operation, result} ->
        case Async.settle_host_reply(execution, operation, result) do
          {:ok, execution} -> await_final_promise(final_promise, execution, finish)
          :stale -> receive_host_reply(final_promise, execution, finish)
        end
    end
  end

  defp await_legacy_promise(%Continuation{} = continuation, finish) do
    receive do
      {:quickbeam_vm_host_reply, operation, result} ->
        case Async.settle_host_reply(continuation.execution, operation, result) do
          {:ok, execution} ->
            continuation = %{continuation | execution: execution}

            if Promise.state(execution, continuation.awaiting) == :pending do
              await_legacy_promise(continuation, finish)
            else
              result = settled_result(continuation.awaiting, execution)
              execution = %{execution | jobs: :queue.in(result, execution.jobs)}

              drive_with(
                {:suspended, %{continuation | execution: execution, awaiting: :microtask}},
                finish
              )
            end

          :stale ->
            await_legacy_promise(continuation, finish)
        end
    end
  end

  defp settled_result(promise, execution) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} -> {:ok, value}
      {:rejected, reason} -> {:error, reason}
    end
  end

  defp then_resume(result, continuation, finish) do
    continuation
    |> Interpreter.resume_raw(result)
    |> drive_with(finish)
  end

  defp measured(fun, opts) do
    ref = make_ref()
    result = fun.(Keyword.put(opts, :measurement_target, {self(), ref}))

    receive do
      {:quickbeam_vm_measurement, ^ref, metrics} -> {result, metrics}
    after
      0 -> {result, nil}
    end
  end

  defp finish_final({status, _value, %State{} = execution} = result)
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

  defp report_measurement(%State{measurement_target: nil}), do: :ok

  defp report_measurement(%State{measurement_target: {pid, ref}} = execution) do
    process_memory = process_stat(:memory)
    reductions = process_stat(:reductions)

    metrics =
      Map.merge(
        %{
          steps: execution.step_limit - execution.remaining_steps,
          logical_memory_bytes: execution.memory_used,
          process_memory_bytes: process_memory,
          reductions: reductions
        },
        Optimization.snapshot(execution)
      )

    send(pid, {:quickbeam_vm_measurement, ref, metrics})

    :ok
  end

  defp process_stat(key) do
    case Process.info(self(), key) do
      {^key, value} -> value
      nil -> nil
    end
  end
end
