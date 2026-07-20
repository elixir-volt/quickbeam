defmodule QuickBEAM.VM.Runtime.ExceptionTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Exception
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Thrown

  test "materializes thrown values and resumes the nearest catch target" do
    execution = execution()
    frame = %{frame("current.js", "current") | pc: 2, stack: [1, {:catch, 7}, :below]}

    assert {:run, resumed, ^execution} = Exception.throw_at("boom", frame, execution)
    assert resumed.pc == 7
    assert resumed.stack == ["boom", :below]
  end

  test "unwinds explicit caller frames into stable JavaScript-only stacks" do
    caller = %{frame("caller.js", "caller") | pc: 1}
    current = %{frame("current.js", "current") | pc: 0}
    execution = %{execution() | callers: [caller], depth: 2}

    assert {:error, %QuickBEAM.JSError{} = error, execution} =
             Exception.throw_at({:type_error, :not_callable}, current, execution)

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

    thenable = %Boundary.Thenable{promise: thenable_promise, depth: 1}
    assert {:idle, execution} = Exception.throw_from("then failed", thenable, execution)
    assert {:rejected, %Thrown{value: "then failed"}} = Promise.state(execution, thenable_promise)

    {executor_promise, execution} = Promise.new(execution)
    caller = frame("caller.js", "caller")

    boundary = %Boundary.PromiseExecutor{
      promise: executor_promise,
      caller: caller,
      depth: 1,
      tail?: false
    }

    assert {:complete, ^executor_promise, ^caller, execution, false} =
             Exception.throw_from("executor failed", boundary, execution)

    assert {:rejected, %Thrown{value: "executor failed"}} =
             Promise.state(execution, executor_promise)
  end

  test "converts async unwinding into an explicit async completion action" do
    execution = execution()
    {promise, execution} = Promise.new(execution)
    caller = frame("caller.js", "caller")
    boundary = %Boundary.Async{promise: promise, caller: caller, depth: 1, mode: :push}
    execution = %{execution | callers: [boundary], depth: 2}

    assert {:async, {:complete, ^promise, ^caller, execution, false}} =
             Exception.throw_at("async failed", frame("async.js", "load"), execution)

    assert {:rejected, %Thrown{value: "async failed", frames: [async_frame]}} =
             Promise.state(execution, promise)

    assert async_frame.function == "load"
    assert execution.callers == []
    assert execution.depth == 1
  end

  defp execution do
    %State{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
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
