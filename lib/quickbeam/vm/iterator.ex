defmodule QuickBEAM.VM.Iterator do
  @moduledoc """
  Implements the canonical iterable-value boundary used by Promise combinators.

  Arrays, sets, strings, and internal BEAM lists can be collected immediately.
  JavaScript objects are consumed through `Symbol.iterator` with explicit
  resumable boundaries for getters, the iterator factory, `next`, `done`, and
  `value`. No JavaScript call is executed recursively.
  """

  alias QuickBEAM.VM.{
    Exceptions,
    Execution,
    Heap,
    Invocation,
    IteratorBoundary,
    Object,
    Promise,
    Property,
    Reference,
    Symbol,
    Value
  }

  @type action :: Invocation.action()

  @doc "Collects values from an iterable whose protocol requires no JavaScript calls."
  @spec values(term(), Execution.t()) :: {:ok, [term()]} | {:resumable} | {:error, :not_iterable}
  def values(value, _execution) when is_list(value), do: {:ok, value}
  def values(value, _execution) when is_binary(value), do: {:ok, String.codepoints(value)}

  def values(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length, properties: properties}} ->
        values =
          if length == 0 do
            []
          else
            for index <- 0..(length - 1), do: property_value(properties, index)
          end

        {:ok, values}

      {:ok, %Object{kind: :set, internal: %{values: values}}} ->
        {:ok, values}

      {:ok, %Object{}} ->
        {:resumable}

      _other ->
        {:error, :not_iterable}
    end
  end

  def values(_value, _execution), do: {:error, :not_iterable}

  @doc "Starts resumable consumption of a JavaScript iterator for a Promise combinator."
  @spec start(atom(), term(), term(), Execution.t(), boolean()) :: action()
  def start(kind, iterable, caller, execution, tail?) do
    {promise, execution} = Promise.new(execution)

    boundary = %IteratorBoundary{
      kind: kind,
      promise: promise,
      iterable: iterable,
      caller: caller,
      depth: execution.depth,
      tail?: tail?
    }

    read_iterator_method(boundary, execution)
  end

  @doc "Resumes iterator consumption after one getter or method invocation."
  @spec resume(term(), IteratorBoundary.t(), Execution.t()) :: action()
  def resume(value, %IteratorBoundary{phase: :iterator_getter} = boundary, execution),
    do: invoke_iterator_factory(%{boundary | phase: nil}, value, execution)

  def resume(iterator, %IteratorBoundary{phase: :iterator_factory} = boundary, execution) do
    if object?(iterator) do
      read_next(%{boundary | iterator: iterator, phase: nil}, execution)
    else
      reject(boundary, {:type_error, :iterator_result_not_object}, execution)
    end
  end

  def resume(value, %IteratorBoundary{phase: :next_getter} = boundary, execution),
    do: invoke_next(%{boundary | phase: nil}, value, execution)

  def resume(result, %IteratorBoundary{phase: :next_call} = boundary, execution) do
    if object?(result) do
      read_done(%{boundary | result: result, phase: nil}, execution)
    else
      reject(boundary, {:type_error, :iterator_result_not_object}, execution)
    end
  end

  def resume(done, %IteratorBoundary{phase: :done_getter} = boundary, execution),
    do: after_done(%{boundary | phase: nil}, done, execution)

  def resume(value, %IteratorBoundary{phase: :value_getter} = boundary, execution),
    do: {:iterator_value, value, %{boundary | phase: nil}, execution}

  @doc "Continues with `next` after synchronous value-resolution work finishes."
  @spec continue(IteratorBoundary.t(), Execution.t()) :: action()
  def continue(%IteratorBoundary{} = boundary, execution),
    do: next_iteration(boundary, execution)

  @doc "Rejects the combinator Promise and returns it to the original caller."
  @spec reject(IteratorBoundary.t(), term(), Execution.t()) :: action()
  def reject(%IteratorBoundary{} = boundary, reason, execution),
    do: reject_now(boundary, reason, execution)

  @doc "Handles a JavaScript throw raised while an iterator boundary is active."
  @spec fail(IteratorBoundary.t(), term(), Execution.t()) :: action()
  def fail(%IteratorBoundary{} = boundary, reason, execution),
    do: reject_now(boundary, reason, execution)

  defp read_iterator_method(boundary, execution) do
    case QuickBEAM.VM.Properties.get(boundary.iterable, Symbol.iterator(), execution) do
      {:ok, {:accessor, getter, receiver}} ->
        dispatch_getter(boundary, :iterator_getter, getter, receiver, execution)

      {:ok, method} ->
        invoke_iterator_factory(boundary, method, execution)

      {:error, reason} ->
        reject(boundary, reason, execution)
    end
  end

  defp invoke_iterator_factory(boundary, method, execution) do
    if Invocation.callable?(method, execution) do
      dispatch(boundary, :iterator_factory, method, [], boundary.iterable, execution)
    else
      reject(boundary, {:type_error, :not_iterable}, execution)
    end
  end

  defp read_next(boundary, execution) do
    case QuickBEAM.VM.Properties.get(boundary.iterator, "next", execution) do
      {:ok, {:accessor, getter, receiver}} ->
        dispatch_getter(boundary, :next_getter, getter, receiver, execution)

      {:ok, next} ->
        invoke_next(boundary, next, execution)

      {:error, reason} ->
        reject(boundary, reason, execution)
    end
  end

  defp invoke_next(boundary, next, execution) do
    if Invocation.callable?(next, execution) do
      dispatch(%{boundary | next: next}, :next_call, next, [], boundary.iterator, execution)
    else
      reject(boundary, {:type_error, :iterator_next_not_callable}, execution)
    end
  end

  defp next_iteration(boundary, execution),
    do: dispatch(boundary, :next_call, boundary.next, [], boundary.iterator, execution)

  defp read_done(boundary, execution) do
    case QuickBEAM.VM.Properties.get(boundary.result, "done", execution) do
      {:ok, {:accessor, getter, receiver}} ->
        dispatch_getter(boundary, :done_getter, getter, receiver, execution)

      {:ok, done} ->
        after_done(boundary, done, execution)

      {:error, reason} ->
        reject(boundary, reason, execution)
    end
  end

  defp after_done(boundary, done, execution) do
    if Value.truthy?(done) do
      values = Enum.reverse(boundary.values)
      execution = Promise.aggregate_into(execution, boundary.promise, boundary.kind, values)
      complete(boundary, execution)
    else
      read_value(boundary, execution)
    end
  end

  defp read_value(boundary, execution) do
    case QuickBEAM.VM.Properties.get(boundary.result, "value", execution) do
      {:ok, {:accessor, getter, receiver}} ->
        dispatch_getter(boundary, :value_getter, getter, receiver, execution)

      {:ok, value} ->
        {:iterator_value, value, boundary, execution}

      {:error, reason} ->
        reject(boundary, reason, execution)
    end
  end

  defp reject_now(boundary, reason, execution) do
    {reason, execution} = Exceptions.materialize(reason, execution)
    execution = Promise.settle(execution, boundary.promise, {:error, reason})
    complete(boundary, execution)
  end

  defp dispatch_getter(boundary, phase, getter, receiver, execution) do
    if Invocation.callable?(getter, execution) do
      dispatch(boundary, phase, getter, [], receiver, execution)
    else
      reject(boundary, {:type_error, :iterator_accessor_not_callable}, execution)
    end
  end

  defp dispatch(boundary, phase, callable, arguments, this, execution),
    do: {:dispatch, callable, arguments, this, %{boundary | phase: phase}, execution, false}

  defp complete(boundary, execution),
    do: {:complete, boundary.promise, boundary.caller, execution, boundary.tail?}

  defp object?(%Reference{}), do: true
  defp object?(value) when is_map(value) and not is_struct(value), do: true
  defp object?(_value), do: false

  defp property_value(properties, index) do
    case Map.get(properties, index) do
      %Property{value: value} -> value
      nil -> :undefined
    end
  end
end
