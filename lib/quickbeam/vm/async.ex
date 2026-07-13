defmodule QuickBEAM.VM.Async do
  @moduledoc """
  Defines canonical state transitions for async functions, Promises, and host tasks.

  The module owns coroutine detachment, Promise reaction planning, async frame
  boundaries, thenable boundaries, microtask suspension, and asynchronous BEAM
  handler startup. It returns explicit actions for the interpreter to execute;
  it never recursively runs interpreter frames.
  """

  alias QuickBEAM.VM.{
    AsyncBoundary,
    Continuation,
    Coroutine,
    Execution,
    Frame,
    Invocation,
    Memory,
    Promise,
    PromiseExecutorBoundary,
    PromiseReference,
    Reaction,
    ReactionBoundary,
    ThenGetterBoundary,
    ThenableBoundary,
    Thrown
  }

  @type result ::
          {:run, Frame.t(), Execution.t()}
          | {:raise, term(), Frame.t(), Execution.t()}
          | {:invoke, term(), [term()], term(), term(), Execution.t(), boolean()}
          | {:complete, term(), term(), Execution.t(), boolean()}
          | {:return, term(), Execution.t()}
          | {:idle, Execution.t()}
          | {:suspended, Continuation.t()}
          | {:error, term(), Execution.t()}

  @doc "Enters an async bytecode function behind an explicit Promise boundary."
  @spec enter(
          QuickBEAM.VM.Function.t(),
          term(),
          tuple(),
          [term()],
          term(),
          term(),
          Execution.t(),
          boolean()
        ) :: result()
  def enter(function, callable, closure_refs, arguments, this, caller, execution, tail?) do
    depth = if tail?, do: execution.depth, else: execution.depth + 1

    if depth > execution.max_stack_depth do
      {:error, {:limit_exceeded, :stack_depth, depth}, execution}
    else
      {promise, execution} = Promise.new(execution)

      mode =
        cond do
          match?(%ReactionBoundary{}, caller) -> :reaction
          match?(%PromiseExecutorBoundary{}, caller) -> :executor
          match?(%ThenableBoundary{}, caller) -> :thenable
          tail? -> :return
          true -> :push
        end

      boundary = %AsyncBoundary{
        promise: promise,
        caller: if(tail?, do: nil, else: caller),
        depth: execution.depth,
        mode: mode
      }

      execution = %{execution | callers: [boundary | execution.callers], depth: depth}
      frame = Invocation.new_frame(function, callable, arguments, this, closure_refs)
      {:run, frame, execution}
    end
  end

  @doc "Restores a detached coroutine and classifies its settlement continuation."
  @spec resume_coroutine(Coroutine.t(), {:ok, term()} | {:error, term()}, Execution.t()) ::
          result()
  def resume_coroutine(%Coroutine{} = coroutine, result, %Execution{} = execution) do
    callers = coroutine.callers ++ [coroutine.boundary]
    frame_depth = Enum.count(coroutine.callers, &match?(%Frame{}, &1))
    execution = %{execution | callers: callers, depth: coroutine.boundary.depth + frame_depth + 1}

    case result do
      {:ok, value} ->
        {:run, %{coroutine.frame | stack: [value | coroutine.frame.stack]}, execution}

      {:error, reason} ->
        {:raise, reason, coroutine.frame, execution}
    end
  end

  @doc "Detaches the nearest async boundary while awaiting a Promise."
  @spec detach_await(Frame.t(), Execution.t(), PromiseReference.t()) ::
          {:ok, result()} | :no_async_boundary
  def detach_await(resume_frame, execution, awaited_promise) do
    detach(resume_frame, execution, fn execution, coroutine ->
      Promise.await(execution, awaited_promise, coroutine)
    end)
  end

  @doc "Detaches the nearest async boundary and queues an immediate await result."
  @spec detach_immediate(Frame.t(), Execution.t(), {:ok, term()} | {:error, term()}) ::
          {:ok, result()} | :no_async_boundary
  def detach_immediate(resume_frame, execution, result) do
    detach(resume_frame, execution, fn execution, coroutine ->
      Promise.enqueue_coroutine(execution, coroutine, result)
    end)
  end

  @doc "Creates a legacy Promise continuation when no async boundary exists."
  @spec suspend_promise(Frame.t(), Execution.t(), PromiseReference.t()) :: result()
  def suspend_promise(resume_frame, execution, promise) do
    case Promise.state(execution, promise) do
      :pending ->
        {:suspended, %Continuation{frame: resume_frame, execution: execution, awaiting: promise}}

      {:fulfilled, value} ->
        suspend_microtask(resume_frame, execution, {:ok, value})

      {:rejected, reason} ->
        suspend_microtask(resume_frame, execution, {:error, reason})
    end
  end

  @doc "Queues an immediate await result and suspends until its microtask turn."
  @spec suspend_microtask(Frame.t(), Execution.t(), {:ok, term()} | {:error, term()}) :: result()
  def suspend_microtask(resume_frame, execution, result) do
    execution = %{execution | jobs: :queue.in(result, execution.jobs)}

    {:suspended, %Continuation{frame: resume_frame, execution: execution, awaiting: :microtask}}
  end

  @doc "Plans invocation of an accessor-backed thenable property."
  @spec read_thenable(PromiseReference.t(), term(), term(), Frame.t() | nil, Execution.t()) ::
          result()
  def read_thenable(promise, thenable, getter, continuation, execution) do
    boundary = %ThenGetterBoundary{
      promise: promise,
      thenable: thenable,
      depth: execution.depth,
      continuation: continuation
    }

    {:invoke, getter, [], thenable, boundary, execution, false}
  end

  @doc "Plans invocation of a callable thenable with idempotent resolver functions."
  @spec assimilate_thenable(PromiseReference.t(), term(), term(), Execution.t()) :: result()
  def assimilate_thenable(promise, thenable, callable, execution) do
    boundary = %ThenableBoundary{promise: promise, depth: execution.depth}
    resolve = {:promise_resolver, promise, :resolve_assimilated}
    reject = {:promise_resolver, promise, :reject_assimilated}
    {:invoke, callable, [resolve, reject], thenable, boundary, execution, false}
  end

  @doc "Plans one FIFO Promise reaction or propagates a missing callback."
  @spec run_reaction(Reaction.t(), {:ok, term()} | {:error, term()}, Execution.t()) :: result()
  def run_reaction(%Reaction{} = reaction, result, %Execution{} = execution) do
    callback =
      case result do
        {:ok, _value} -> reaction.on_fulfilled
        {:error, _reason} -> reaction.on_rejected
      end

    if Invocation.callable?(callback, execution) do
      boundary = %ReactionBoundary{
        promise: reaction.result_promise,
        depth: execution.depth,
        mode: reaction.kind,
        original_result: result
      }

      arguments = if reaction.kind == :finally, do: [], else: [reaction_argument(result)]
      {:invoke, callback, arguments, :undefined, boundary, execution, false}
    else
      {:idle, Promise.settle(execution, reaction.result_promise, result)}
    end
  end

  @doc "Completes an accessor-backed thenable read and resumes its continuation."
  @spec complete_then_getter(term(), ThenGetterBoundary.t(), Execution.t()) :: result()
  def complete_then_getter(value, boundary, execution) do
    execution =
      if Invocation.callable?(value, execution) do
        Promise.enqueue_assimilation(execution, boundary.promise, boundary.thenable, value)
      else
        Promise.fulfill_assimilated(execution, boundary.promise, boundary.thenable)
      end

    case boundary.continuation do
      %Frame{} = frame -> {:run, frame, execution}
      nil -> {:idle, execution}
    end
  end

  @doc "Completes a Promise reaction boundary."
  @spec complete_reaction(ReactionBoundary.t(), term(), Execution.t()) :: result()
  def complete_reaction(%ReactionBoundary{mode: :then} = boundary, value, execution),
    do: {:idle, Promise.settle(execution, boundary.promise, {:ok, value})}

  def complete_reaction(%ReactionBoundary{mode: :finally} = boundary, value, execution) do
    {completion, execution} =
      case value do
        %PromiseReference{} = promise ->
          {promise, execution}

        value ->
          {promise, execution} = Promise.new(execution)
          {promise, Promise.settle(execution, promise, {:ok, value})}
      end

    execution =
      Promise.settle_after_finally(
        execution,
        completion,
        boundary.promise,
        boundary.original_result
      )

    {:idle, execution}
  end

  @doc "Settles an async function Promise and returns its boundary-delivery action."
  @spec complete(AsyncBoundary.t(), {:ok, term()} | {:error, term()}, Execution.t()) :: result()
  def complete(%AsyncBoundary{} = boundary, result, execution) do
    execution = Promise.settle(execution, boundary.promise, result)
    deliver(boundary, execution)
  end

  @doc "Settles a correlated asynchronous host reply, ignoring stale operations."
  @spec settle_host_reply(Execution.t(), reference(), {:ok, term()} | {:error, term()}) ::
          {:ok, Execution.t()} | :stale
  def settle_host_reply(execution, operation, result) do
    case Map.pop(execution.operations, operation) do
      {nil, _operations} ->
        :stale

      {{promise, _pid}, operations} ->
        execution = %{execution | operations: operations}
        execution = Memory.charge(execution, Memory.estimate(elem(result, 1)))
        {:ok, Promise.settle(execution, promise, result)}
    end
  end

  @doc "Cancels every outstanding handler task owned by an evaluation."
  @spec cancel_operations(Execution.t() | map()) :: :ok
  def cancel_operations(%Execution{operations: operations}), do: cancel_operations(operations)

  def cancel_operations(operations) when is_map(operations) do
    Enum.each(operations, fn {_operation, {_promise, pid}} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  @doc "Starts an asynchronous BEAM handler and returns its owner-local Promise."
  @spec start_host_call([term()], Execution.t()) ::
          {:ok, PromiseReference.t(), Execution.t()} | {:error, term(), Execution.t()}
  def start_host_call([name | arguments], execution) when is_binary(name) do
    {promise, execution} = Promise.new(execution)

    execution =
      case Map.fetch(execution.handlers, name) do
        {:ok, handler} -> start_handler_task(handler, arguments, promise, execution)
        :error -> Promise.settle(execution, promise, {:error, {:unknown_handler, name}})
      end

    {:ok, promise, execution}
  end

  def start_host_call(_arguments, execution),
    do: {:error, {:type_error, :invalid_beam_call}, execution}

  defp detach(resume_frame, execution, enqueue_resume) do
    case Enum.split_while(execution.callers, &(!match?(%AsyncBoundary{}, &1))) do
      {inner_callers, [%AsyncBoundary{} = boundary | outer_callers]} ->
        coroutine = %Coroutine{
          frame: resume_frame,
          callers: inner_callers,
          boundary: %{boundary | caller: nil, depth: 0, mode: :detached}
        }

        execution = %{execution | callers: outer_callers, depth: boundary.depth}
        execution = enqueue_resume.(execution, coroutine)
        {:ok, deliver(boundary, execution)}

      {_callers, []} ->
        :no_async_boundary
    end
  end

  defp deliver(%AsyncBoundary{mode: :push, caller: caller, promise: promise}, execution),
    do: {:complete, promise, caller, execution, false}

  defp deliver(%AsyncBoundary{mode: :return, promise: promise}, execution),
    do: {:return, promise, execution}

  defp deliver(
         %AsyncBoundary{mode: :reaction, caller: boundary, promise: promise},
         execution
       ),
       do: complete_reaction(boundary, promise, execution)

  defp deliver(%AsyncBoundary{mode: :executor, caller: boundary}, execution),
    do: {:complete, boundary.promise, boundary.caller, execution, boundary.tail?}

  defp deliver(%AsyncBoundary{mode: mode}, execution) when mode in [:thenable, :detached],
    do: {:idle, execution}

  defp reaction_argument({:ok, value}), do: value
  defp reaction_argument({:error, %Thrown{value: value}}), do: value
  defp reaction_argument({:error, reason}), do: reason

  defp start_handler_task(handler, arguments, promise, execution) do
    operation = make_ref()
    owner = self()

    case Task.Supervisor.start_child(QuickBEAM.VM.TaskSupervisor, fn ->
           Process.link(owner)
           result = invoke_handler(handler, arguments)
           send(owner, {:quickbeam_vm_host_reply, operation, result})
         end) do
      {:ok, pid} ->
        %{execution | operations: Map.put(execution.operations, operation, {promise, pid})}

      {:error, reason} ->
        Promise.settle(execution, promise, {:error, {:handler_start_failed, reason}})
    end
  end

  defp invoke_handler(handler, arguments) do
    {:ok, handler.(arguments)}
  rescue
    exception -> {:error, {:handler_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:handler_exception, {kind, reason}, __STACKTRACE__}}
  end
end
