defmodule QuickBEAM.VM.Builtin.Promise do
  @moduledoc "Defines the declarative Promise constructor, statics, and reactions."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Call

  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Exception
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Iterator
  alias QuickBEAM.VM.Runtime.Promise

  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference

  builtin "Promise",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function", "Symbol"] do
    static :all, length: 1
    static :all_settled, js: "allSettled", length: 1
    static :any, length: 1
    static :race, length: 1
    static :reject, length: 1
    static :resolve, length: 1

    prototype do
      method :catch_method, js: "catch", length: 1
      method :finally_method, js: "finally", length: 1
      method :then, length: 2
    end
  end

  @doc "Constructs a Promise and invokes its executor synchronously."
  def construct(%Call{
        arguments: [executor | _],
        caller: %Boundary.Constructor{} = caller,
        execution: execution
      }) do
    if Invocation.callable?(executor, execution) do
      {promise, execution} = Promise.new(execution)

      boundary = %Boundary.PromiseExecutor{
        promise: promise,
        caller: caller,
        depth: execution.depth,
        tail?: false
      }

      resolve = {:promise_resolver, promise, :resolve}
      reject = {:promise_resolver, promise, :reject}

      Builtin.action(
        {:dispatch, executor, [resolve, reject], :undefined, boundary, execution, false}
      )
    else
      {:error, :promise_executor_not_callable, execution}
    end
  end

  def construct(%Call{caller: %Boundary.Constructor{}, execution: execution}),
    do: {:error, :missing_promise_executor, execution}

  def construct(%Call{execution: execution}),
    do: {:error, :promise_constructor_requires_new, execution}

  @doc "Implements `Promise.resolve`."
  def resolve(%Call{arguments: [%PromiseReference{} = promise | _], execution: execution}),
    do: {:ok, promise, execution}

  def resolve(%Call{arguments: arguments, execution: execution}) do
    {promise, execution} = Promise.new(execution)
    value = List.first(arguments, :undefined)
    {:ok, promise, Promise.settle(execution, promise, {:ok, value})}
  end

  @doc "Implements `Promise.reject`."
  def reject(%Call{arguments: arguments, execution: execution}) do
    {promise, execution} = Promise.new(execution)
    reason = List.first(arguments, :undefined)
    {:ok, promise, Promise.settle(execution, promise, {:error, reason})}
  end

  @doc "Implements `Promise.all` over the canonical iterable boundary."
  def all(%Call{} = call), do: aggregate(:all, call)

  @doc "Implements `Promise.allSettled` over the canonical iterable boundary."
  def all_settled(%Call{} = call), do: aggregate(:all_settled, call)

  @doc "Implements `Promise.any` over the canonical iterable boundary."
  def any(%Call{} = call), do: aggregate(:any, call)

  @doc "Implements `Promise.race` over the canonical iterable boundary."
  def race(%Call{} = call), do: aggregate(:race, call)

  @doc "Implements `Promise.prototype.then`."
  def then(%Call{this: %PromiseReference{} = source, arguments: arguments, execution: execution}) do
    on_fulfilled = Enum.at(arguments, 0, :undefined)
    on_rejected = Enum.at(arguments, 1, :undefined)
    {result, execution} = Promise.react(execution, source, on_fulfilled, on_rejected)
    {:ok, result, execution}
  end

  def then(%Call{execution: execution}), do: {:error, :incompatible_promise_receiver, execution}

  @doc "Implements `Promise.prototype.catch`."
  def catch_method(%Call{
        this: %PromiseReference{} = source,
        arguments: arguments,
        execution: execution
      }) do
    on_rejected = Enum.at(arguments, 0, :undefined)
    {result, execution} = Promise.react(execution, source, :undefined, on_rejected)
    {:ok, result, execution}
  end

  def catch_method(%Call{execution: execution}),
    do: {:error, :incompatible_promise_receiver, execution}

  @doc "Implements `Promise.prototype.finally`."
  def finally_method(%Call{
        this: %PromiseReference{} = source,
        arguments: arguments,
        execution: execution
      }) do
    callback = Enum.at(arguments, 0, :undefined)
    {result, execution} = Promise.finally(execution, source, callback)
    {:ok, result, execution}
  end

  def finally_method(%Call{execution: execution}),
    do: {:error, :incompatible_promise_receiver, execution}

  defp aggregate(kind, %Call{arguments: arguments, execution: execution} = call) do
    iterable = List.first(arguments, :undefined)

    case Iterator.values(iterable, execution) do
      {:ok, values} ->
        {promise, execution} = Promise.aggregate(execution, kind, values)
        {:ok, promise, execution}

      {:resumable} ->
        Builtin.action({:promise_iterate, kind, iterable, call.caller, execution, call.tail?})

      {:error, :not_iterable} ->
        {reason, execution} = Exception.materialize({:type_error, :not_iterable}, execution)
        {promise, execution} = Promise.new(execution)
        execution = Promise.settle(execution, promise, {:error, reason})
        {:ok, promise, execution}
    end
  end
end
