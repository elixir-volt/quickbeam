defmodule QuickBEAM.VM.Evaluator do
  @moduledoc false

  alias QuickBEAM.VM.{Continuation, Interpreter, Promise, PromiseReference, Program}

  @spec eval(Program.t(), keyword()) :: Interpreter.result()
  def eval(%Program{} = program, opts \\ []) do
    program
    |> Interpreter.start(opts)
    |> drive()
  end

  defp drive({:suspended, %Continuation{awaiting: :microtask} = continuation}) do
    case :queue.out(continuation.execution.jobs) do
      {{:value, result}, jobs} ->
        continuation = %{continuation | execution: %{continuation.execution | jobs: jobs}}
        then_resume(result, continuation)

      {:empty, _jobs} ->
        {:error, :missing_microtask}
    end
  end

  defp drive({:suspended, %Continuation{awaiting: %PromiseReference{}} = continuation}) do
    await_host_reply(continuation)
  end

  defp drive({:suspended, _continuation} = suspended), do: Interpreter.finish(suspended)

  defp drive({status, _value, execution} = result) when status in [:ok, :error] do
    cancel_operations(execution.operations)
    Interpreter.finish(result)
  end

  defp await_host_reply(%Continuation{} = continuation) do
    receive do
      {:quickbeam_vm_host_reply, operation, result} ->
        case Map.pop(continuation.execution.operations, operation) do
          {nil, _operations} ->
            await_host_reply(continuation)

          {{promise, _pid}, operations} ->
            execution = %{continuation.execution | operations: operations}
            execution = Promise.settle(execution, promise, result)
            continuation = %{continuation | execution: execution}

            if promise.id == continuation.awaiting.id do
              result = settled_result(promise, execution)
              execution = %{execution | jobs: :queue.in(result, execution.jobs)}
              drive({:suspended, %{continuation | execution: execution, awaiting: :microtask}})
            else
              await_host_reply(continuation)
            end
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

  defp cancel_operations(operations) do
    Enum.each(operations, fn {_operation, {_promise, pid}} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end
end
