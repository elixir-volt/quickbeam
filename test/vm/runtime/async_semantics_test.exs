defmodule QuickBEAM.VM.Runtime.AsyncSemanticsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Async
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.Promise.Reaction
  alias QuickBEAM.VM.Runtime.State

  test "enters async functions through an owner-local Promise boundary" do
    execution = execution()
    caller = frame()
    function = %Function{id: 1, func_kind: 2, arg_count: 1}

    assert {:run, %Frame{function: ^function, args: {7}}, execution} =
             Async.enter(function, function, {}, [7], :receiver, caller, execution, false)

    assert %Boundary.Async{mode: :push, caller: ^caller, promise: promise} =
             hd(execution.callers)

    assert Promise.state(execution, promise) == :pending
    assert execution.depth == 2
  end

  test "detaches await state into a coroutine waiter and delivers the async Promise" do
    execution = execution()
    caller = frame()
    function = %Function{id: 2, func_kind: 2}

    {:run, resume_frame, execution} =
      Async.enter(function, function, {}, [], :undefined, caller, execution, false)

    {awaited, execution} = Promise.new(execution)

    assert {:ok, {:complete, async_promise, ^caller, execution, false}} =
             Async.detach_await(resume_frame, execution, awaited)

    assert Promise.state(execution, async_promise) == :pending
    assert [_coroutine] = Map.fetch!(execution.promise_waiters, awaited.id)
    assert execution.callers == []
    assert execution.depth == 1
  end

  test "Promise reactions either invoke callbacks or propagate settlements" do
    execution = execution()
    {result_promise, execution} = Promise.new(execution)

    reaction = %Reaction{
      result_promise: result_promise,
      on_fulfilled: :undefined,
      on_rejected: :undefined
    }

    assert {:idle, execution} = Async.run_reaction(reaction, {:ok, 42}, execution)
    assert Promise.state(execution, result_promise) == {:fulfilled, 42}

    {next_promise, execution} = Promise.new(execution)
    reaction = %{reaction | result_promise: next_promise, on_fulfilled: {:builtin, "callback"}}

    assert {:invoke, {:builtin, "callback"}, [42], :undefined, boundary, ^execution, false} =
             Async.run_reaction(reaction, {:ok, 42}, execution)

    assert boundary.promise == next_promise
  end

  test "correlates host replies and settles their owner-local Promises" do
    execution = execution()
    {promise, execution} = Promise.new(execution)
    operation = make_ref()
    execution = %{execution | operations: %{operation => {promise, self()}}}

    assert {:ok, execution} = Async.settle_host_reply(execution, operation, {:ok, %{"x" => 1}})
    assert execution.operations == %{}
    assert execution.memory_used > 0
    assert Promise.state(execution, promise) == {:fulfilled, %{"x" => 1}}
    assert Async.settle_host_reply(execution, operation, {:ok, 2}) == :stale
  end

  test "host calls return explicit errors and owner-local rejected Promises" do
    execution = execution()

    assert {:error, {:type_error, :invalid_beam_call}, ^execution} =
             Async.start_host_call([], execution)

    assert {:ok, promise, execution} = Async.start_host_call(["missing"], execution)
    assert Promise.state(execution, promise) == {:rejected, {:unknown_handler, "missing"}}
  end

  defp execution do
    %State{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end

  defp frame do
    function = %Function{id: 0}
    Invocation.new_frame(function, function, [], :undefined, {})
  end
end
