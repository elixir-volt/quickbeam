defmodule QuickBEAM.VM.Runtime.Promise do
  @moduledoc """
  Implements owner-local Promise state, reactions, adoption, and combinators.

  Promise state and jobs live in `QuickBEAM.VM.Runtime.State`; this module only
  transforms that explicit state and never starts independent processes.
  """

  alias QuickBEAM.VM.Runtime.Coroutine
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Memory
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference
  alias QuickBEAM.VM.Runtime.Promise.Reaction
  alias QuickBEAM.VM.Runtime.Reference

  @type state :: :pending | {:fulfilled, term()} | {:rejected, term()}

  @doc "Allocates a pending owner-local Promise."
  @spec new(State.t()) :: {PromiseReference.t(), State.t()}
  def new(%State{} = execution) do
    id = execution.next_promise_id
    reference = %PromiseReference{id: id}
    execution = Memory.charge_promise(execution)

    execution = %{
      execution
      | next_promise_id: id + 1,
        promises: Map.put(execution.promises, id, :pending)
    }

    {reference, execution}
  end

  @doc "Returns the observable state of an owner-local Promise."
  @spec state(State.t(), PromiseReference.t()) :: state()
  def state(%State{} = execution, %PromiseReference{id: id}) do
    case Map.fetch!(execution.promises, id) do
      :resolving -> :pending
      state -> state
    end
  end

  @doc "Registers a coroutine to resume when a Promise settles."
  @spec await(State.t(), PromiseReference.t(), Coroutine.t()) :: State.t()
  def await(execution, %PromiseReference{id: id} = promise, %Coroutine{} = coroutine) do
    case state(execution, promise) do
      :pending -> add_waiter(execution, id, coroutine)
      {:fulfilled, value} -> enqueue(execution, {:resume_coroutine, coroutine, {:ok, value}})
      {:rejected, reason} -> enqueue(execution, {:resume_coroutine, coroutine, {:error, reason}})
    end
  end

  @doc "Creates a chained Promise reaction."
  @spec react(State.t(), PromiseReference.t(), term(), term()) ::
          {PromiseReference.t(), State.t()}
  def react(execution, %PromiseReference{id: id} = source, on_fulfilled, on_rejected) do
    {result_promise, execution} = new(execution)

    reaction = %Reaction{
      result_promise: result_promise,
      on_fulfilled: on_fulfilled,
      on_rejected: on_rejected
    }

    execution =
      case state(execution, source) do
        :pending -> add_waiter(execution, id, reaction)
        {:fulfilled, value} -> enqueue(execution, {:run_reaction, reaction, {:ok, value}})
        {:rejected, reason} -> enqueue(execution, {:run_reaction, reaction, {:error, reason}})
      end

    {result_promise, execution}
  end

  @doc "Creates or reuses the Promise produced by resolving one value."
  @spec from_value(State.t(), term()) :: {PromiseReference.t(), State.t()}
  def from_value(execution, value), do: promise_from_value(execution, value)

  @doc "Creates a Promise combinator over a bounded value list."
  @spec aggregate(State.t(), :all | :all_settled | :any | :race, [term()]) ::
          {PromiseReference.t(), State.t()}
  def aggregate(execution, kind, values) do
    {result_promise, execution} = new(execution)
    execution = aggregate_into(execution, result_promise, kind, values)
    {result_promise, execution}
  end

  @doc "Aggregates iterable values into an existing owner-local Promise."
  @spec aggregate_into(
          State.t(),
          PromiseReference.t(),
          :all | :all_settled | :any | :race,
          [term()]
        ) :: State.t()
  def aggregate_into(execution, result_promise, kind, values) do
    if values == [] do
      result =
        case kind do
          :all -> {:ok, []}
          :all_settled -> {:ok, []}
          :any -> {:error, aggregate_error([])}
          :race -> nil
        end

      if result, do: settle(execution, result_promise, result), else: execution
    else
      id = make_ref()

      aggregate = %{
        kind: kind,
        promise: result_promise,
        remaining: length(values),
        values: %{}
      }

      execution = %{
        execution
        | promise_aggregates: Map.put(execution.promise_aggregates, id, aggregate)
      }

      execution =
        values
        |> Enum.with_index()
        |> Enum.reduce(execution, fn {value, index}, execution ->
          {source, execution} = promise_from_value(execution, value)
          add_aggregate_waiter(execution, source, id, index)
        end)

      execution
    end
  end

  @doc "Records one settlement in an active Promise aggregate."
  @spec settle_aggregate(
          State.t(),
          reference(),
          non_neg_integer(),
          {:ok, term()} | {:error, term()}
        ) ::
          State.t()
  def settle_aggregate(execution, id, index, result) do
    case Map.fetch(execution.promise_aggregates, id) do
      :error ->
        execution

      {:ok, aggregate} ->
        update_aggregate(execution, id, aggregate, index, result)
    end
  end

  @doc "Creates a Promise `finally` reaction."
  @spec finally(State.t(), PromiseReference.t(), term()) ::
          {PromiseReference.t(), State.t()}
  def finally(execution, %PromiseReference{id: id} = source, callback) do
    {result_promise, execution} = new(execution)

    reaction = %Reaction{
      result_promise: result_promise,
      kind: :finally,
      on_fulfilled: callback,
      on_rejected: callback
    }

    execution =
      case state(execution, source) do
        :pending -> add_waiter(execution, id, reaction)
        {:fulfilled, value} -> enqueue(execution, {:run_reaction, reaction, {:ok, value}})
        {:rejected, reason} -> enqueue(execution, {:run_reaction, reaction, {:error, reason}})
      end

    {result_promise, execution}
  end

  @doc "Settles a target Promise after a `finally` callback result."
  @spec settle_after_finally(
          State.t(),
          PromiseReference.t(),
          PromiseReference.t(),
          {:ok, term()} | {:error, term()}
        ) :: State.t()
  def settle_after_finally(execution, source, target, original_result) do
    case state(execution, source) do
      :pending -> add_waiter(execution, source.id, {:finally_adopt, target, original_result})
      {:fulfilled, _value} -> settle(execution, target, original_result)
      {:rejected, reason} -> settle(execution, target, {:error, reason})
    end
  end

  @doc "Enqueues invocation of a callable `then` result as a Promise microtask."
  @spec enqueue_assimilation(State.t(), PromiseReference.t(), Reference.t(), term()) ::
          State.t()
  def enqueue_assimilation(execution, promise, thenable, callable),
    do: enqueue(execution, {:assimilate_thenable, promise, thenable, callable})

  @doc "Enqueues a coroutine resumption as a Promise job."
  @spec enqueue_coroutine(State.t(), Coroutine.t(), {:ok, term()} | {:error, term()}) ::
          State.t()
  def enqueue_coroutine(execution, %Coroutine{} = coroutine, result),
    do: enqueue(execution, {:resume_coroutine, coroutine, result})

  @doc "Settles a Promise according to the Promise resolution procedure."
  @spec settle(State.t(), PromiseReference.t(), {:ok, term()} | {:error, term()}) ::
          State.t()
  def settle(execution, %PromiseReference{id: id} = promise, {:ok, %PromiseReference{id: id}}),
    do: settle(execution, promise, {:error, {:type_error, :promise_self_resolution}})

  def settle(execution, %PromiseReference{id: id} = promise, {:ok, %PromiseReference{} = source}) do
    case Map.fetch!(execution.promises, id) do
      :pending ->
        case state(execution, source) do
          :pending ->
            execution = %{execution | promises: Map.put(execution.promises, id, :resolving)}
            add_waiter(execution, source.id, {:adopt, promise})

          {:fulfilled, value} ->
            settle(execution, promise, {:ok, value})

          {:rejected, reason} ->
            settle(execution, promise, {:error, reason})
        end

      _settled_or_resolving ->
        execution
    end
  end

  def settle(execution, %PromiseReference{id: id} = promise, {:ok, %Reference{} = value} = result) do
    case Map.fetch!(execution.promises, id) do
      :pending ->
        case then_callable(execution, value) do
          {:ok, callable} ->
            execution = %{execution | promises: Map.put(execution.promises, id, :resolving)}
            enqueue(execution, {:assimilate_thenable, promise, value, callable})

          {:getter, getter, receiver} ->
            execution = %{execution | promises: Map.put(execution.promises, id, :resolving)}
            enqueue_sync(execution, {:read_thenable, promise, receiver, getter})

          :none ->
            settle_result(execution, promise, result)
        end

      _settled_or_resolving ->
        execution
    end
  end

  def settle(%State{} = execution, %PromiseReference{} = promise, result),
    do: settle_result(execution, promise, result)

  @doc """
  Settles a Promise whose resolution was locked while adopting another value.

  The adopted value is recursively resolved according to the Promise resolution
  procedure, including Promise and thenable assimilation.
  """
  @spec settle_assimilated(State.t(), PromiseReference.t(), {:ok, term()} | {:error, term()}) ::
          State.t()
  def settle_assimilated(execution, %PromiseReference{id: id} = promise, result) do
    case Map.fetch!(execution.promises, id) do
      :resolving ->
        execution = %{execution | promises: Map.put(execution.promises, id, :pending)}
        settle(execution, promise, result)

      _settled ->
        execution
    end
  end

  @doc "Fulfills a resolving Promise after a non-callable `then` getter result."
  @spec fulfill_assimilated(State.t(), PromiseReference.t(), term()) :: State.t()
  def fulfill_assimilated(execution, %PromiseReference{id: id} = promise, value) do
    case Map.fetch!(execution.promises, id) do
      :resolving ->
        execution = %{execution | promises: Map.put(execution.promises, id, :pending)}
        settle_result(execution, promise, {:ok, value})

      _settled ->
        execution
    end
  end

  defp settle_result(%State{} = execution, %PromiseReference{id: id}, result) do
    case Map.fetch!(execution.promises, id) do
      :pending ->
        state = result_state(result)
        {waiters, promise_waiters} = Map.pop(execution.promise_waiters, id, [])

        execution = %{
          execution
          | promises: Map.put(execution.promises, id, state),
            promise_waiters: promise_waiters
        }

        waiters
        |> Enum.reverse()
        |> Enum.reduce(execution, &enqueue_waiter(&2, &1, result))

      _settled ->
        execution
    end
  end

  defp then_callable(execution, reference) do
    case Property.get(reference, "then", execution) do
      {:ok, {:accessor, getter, receiver}} ->
        {:getter, getter, receiver}

      {:ok, %Reference{} = callable} ->
        if Invocation.callable?(callable, execution), do: {:ok, callable}, else: :none

      {:ok, callable}
      when is_tuple(callable) and
             elem(callable, 0) in [
               :bound_function,
               :builtin,
               :declared_builtin,
               :host_function,
               :primitive_method,
               :promise_resolver
             ] ->
        {:ok, callable}

      _ ->
        :none
    end
  end

  defp promise_from_value(execution, %PromiseReference{} = promise), do: {promise, execution}

  defp promise_from_value(execution, value) do
    {promise, execution} = new(execution)
    {promise, settle(execution, promise, {:ok, value})}
  end

  defp add_aggregate_waiter(execution, promise, id, index) do
    case state(execution, promise) do
      :pending -> add_waiter(execution, promise.id, {:aggregate, id, index})
      {:fulfilled, value} -> enqueue(execution, {:aggregate_settle, id, index, {:ok, value}})
      {:rejected, reason} -> enqueue(execution, {:aggregate_settle, id, index, {:error, reason}})
    end
  end

  defp update_aggregate(execution, id, %{kind: :race} = aggregate, _index, result) do
    execution = %{execution | promise_aggregates: Map.delete(execution.promise_aggregates, id)}
    settle(execution, aggregate.promise, result)
  end

  defp update_aggregate(execution, id, %{kind: :all} = aggregate, index, {:ok, value}) do
    aggregate = %{
      aggregate
      | remaining: aggregate.remaining - 1,
        values: Map.put(aggregate.values, index, value)
    }

    finish_or_store_aggregate(execution, id, aggregate)
  end

  defp update_aggregate(execution, id, %{kind: :all} = aggregate, _index, {:error, reason}) do
    execution = %{execution | promise_aggregates: Map.delete(execution.promise_aggregates, id)}
    settle(execution, aggregate.promise, {:error, reason})
  end

  defp update_aggregate(execution, id, %{kind: :all_settled} = aggregate, index, result) do
    value =
      case result do
        {:ok, value} -> %{"status" => "fulfilled", "value" => value}
        {:error, reason} -> %{"status" => "rejected", "reason" => unwrap_reason(reason)}
      end

    aggregate = %{
      aggregate
      | remaining: aggregate.remaining - 1,
        values: Map.put(aggregate.values, index, value)
    }

    finish_or_store_aggregate(execution, id, aggregate)
  end

  defp update_aggregate(execution, id, %{kind: :any} = aggregate, _index, {:ok, value}) do
    execution = %{execution | promise_aggregates: Map.delete(execution.promise_aggregates, id)}
    settle(execution, aggregate.promise, {:ok, value})
  end

  defp update_aggregate(execution, id, %{kind: :any} = aggregate, index, {:error, reason}) do
    aggregate = %{
      aggregate
      | remaining: aggregate.remaining - 1,
        values: Map.put(aggregate.values, index, unwrap_reason(reason))
    }

    if aggregate.remaining == 0 do
      execution = %{execution | promise_aggregates: Map.delete(execution.promise_aggregates, id)}
      settle(execution, aggregate.promise, {:error, aggregate_error(ordered_values(aggregate))})
    else
      %{execution | promise_aggregates: Map.put(execution.promise_aggregates, id, aggregate)}
    end
  end

  defp finish_or_store_aggregate(execution, id, aggregate) do
    if aggregate.remaining == 0 do
      execution = %{execution | promise_aggregates: Map.delete(execution.promise_aggregates, id)}
      settle(execution, aggregate.promise, {:ok, ordered_values(aggregate)})
    else
      %{execution | promise_aggregates: Map.put(execution.promise_aggregates, id, aggregate)}
    end
  end

  defp ordered_values(aggregate) do
    for index <- 0..(map_size(aggregate.values) - 1), do: Map.fetch!(aggregate.values, index)
  end

  defp aggregate_error(errors),
    do: %{
      "name" => "AggregateError",
      "message" => "All promises were rejected",
      "errors" => errors
    }

  defp unwrap_reason(%QuickBEAM.VM.Runtime.Thrown{value: value}), do: value
  defp unwrap_reason(reason), do: reason

  defp result_state({:ok, value}), do: {:fulfilled, value}
  defp result_state({:error, reason}), do: {:rejected, reason}

  defp add_waiter(execution, id, waiter) do
    waiters = Map.update(execution.promise_waiters, id, [waiter], &[waiter | &1])
    %{execution | promise_waiters: waiters}
  end

  defp enqueue_waiter(execution, %Coroutine{} = coroutine, result),
    do: enqueue(execution, {:resume_coroutine, coroutine, result})

  defp enqueue_waiter(execution, {:adopt, target}, result),
    do: enqueue(execution, {:settle_assimilated, target, result})

  defp enqueue_waiter(execution, %Reaction{} = reaction, result),
    do: enqueue(execution, {:run_reaction, reaction, result})

  defp enqueue_waiter(execution, {:finally_adopt, target, original_result}, {:ok, _value}),
    do: enqueue(execution, {:settle_promise, target, original_result})

  defp enqueue_waiter(execution, {:finally_adopt, target, _original_result}, {:error, reason}),
    do: enqueue(execution, {:settle_promise, target, {:error, reason}})

  defp enqueue_waiter(execution, {:aggregate, id, index}, result),
    do: enqueue(execution, {:aggregate_settle, id, index, result})

  defp enqueue(execution, job), do: %{execution | jobs: :queue.in(job, execution.jobs)}

  defp enqueue_sync(execution, job),
    do: %{execution | sync_jobs: :queue.in(job, execution.sync_jobs)}
end
