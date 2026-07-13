defmodule QuickBEAM.VM.ExceptionsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{
    AsyncBoundary,
    Execution,
    Exceptions,
    Frame,
    Function,
    Promise,
    PromiseExecutorBoundary,
    ThenableBoundary,
    Thrown
  }

  test "materializes thrown values and resumes the nearest catch target" do
    execution = execution()
    frame = %{frame("current.js", "current") | pc: 2, stack: [1, {:catch, 7}, :below]}

    assert {:run, resumed, ^execution} = Exceptions.throw_at("boom", frame, execution)
    assert resumed.pc == 7
    assert resumed.stack == ["boom", :below]
  end

  test "unwinds explicit caller frames into stable JavaScript-only stacks" do
    caller = %{frame("caller.js", "caller") | pc: 1}
    current = %{frame("current.js", "current") | pc: 0}
    execution = %{execution() | callers: [caller], depth: 2}

    assert {:error, %QuickBEAM.JSError{} = error, execution} =
             Exceptions.throw_at({:type_error, :not_callable}, current, execution)

    assert Enum.map(error.frames, & &1.function) == ["current", "caller"]
    assert Enum.map(error.frames, & &1.filename) == ["current.js", "caller.js"]
    assert execution.depth == 1
  end

  test "rejects thenable and Promise executor boundaries with preserved thrown state" do
    execution = execution()
    {thenable_promise, execution} = Promise.new(execution)

    execution = %{
      execution
      | promises: Map.put(execution.promises, thenable_promise.id, :resolving)
    }

    thenable = %ThenableBoundary{promise: thenable_promise, depth: 1}
    assert {:idle, execution} = Exceptions.throw_from("then failed", thenable, execution)
    assert {:rejected, %Thrown{value: "then failed"}} = Promise.state(execution, thenable_promise)

    {executor_promise, execution} = Promise.new(execution)
    caller = frame("caller.js", "caller")

    boundary = %PromiseExecutorBoundary{
      promise: executor_promise,
      caller: caller,
      depth: 1,
      tail?: false
    }

    assert {:complete, ^executor_promise, ^caller, execution, false} =
             Exceptions.throw_from("executor failed", boundary, execution)

    assert {:rejected, %Thrown{value: "executor failed"}} =
             Promise.state(execution, executor_promise)
  end

  test "converts async unwinding into an explicit async completion action" do
    execution = execution()
    {promise, execution} = Promise.new(execution)
    caller = frame("caller.js", "caller")
    boundary = %AsyncBoundary{promise: promise, caller: caller, depth: 1, mode: :push}
    execution = %{execution | callers: [boundary], depth: 2}

    assert {:async, {:complete, ^promise, ^caller, execution, false}} =
             Exceptions.throw_at("async failed", frame("async.js", "load"), execution)

    assert {:rejected, %Thrown{value: "async failed", frames: [async_frame]}} =
             Promise.state(execution, promise)

    assert async_frame.function == "load"
    assert execution.callers == []
    assert execution.depth == 1
  end

  defp execution do
    %Execution{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end

  defp frame(filename, name) do
    function = %Function{
      id: name,
      name: name,
      filename: filename,
      line_num: 3,
      col_num: 4,
      instructions: {{0, []}}
    }

    %Frame{function: function, callable: function, locals: {}, args: {}, stack: []}
  end
end
