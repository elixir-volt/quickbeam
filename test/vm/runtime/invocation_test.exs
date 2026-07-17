defmodule QuickBEAM.VM.Runtime.InvocationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Builtin.Action
  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.State

  test "plans ordinary and closure calls as explicit frame entries" do
    execution = execution()
    function = %Function{id: 1, arg_count: 1, var_count: 2}
    caller = frame()

    assert {:enter, ^function, ^function, {}, [7], :receiver, ^caller, ^execution, false} =
             Invocation.plan(function, [7], :receiver, caller, execution)

    closure = {:closure, function, {:cell}}

    assert {:enter, ^function, ^closure, {:cell}, [], :undefined, ^caller, ^execution, true} =
             Invocation.plan(closure, [], :undefined, caller, execution, true)

    assert %Frame{locals: locals, args: {7}, this: :receiver} =
             Invocation.new_frame(function, function, [7], :receiver, {})

    assert tuple_size(locals) == 3
  end

  test "normal and constructor bound calls select the correct receiver" do
    execution = execution()
    caller = frame()
    bound = {:bound_function, :target, :bound_receiver, [1]}

    assert {:dispatch, :target, [1, 2], :bound_receiver, ^caller, ^execution, false} =
             Invocation.plan(bound, [2], :ignored, caller, execution)

    boundary = %Boundary.Constructor{instance: :instance, caller: caller, depth: 1}

    assert {:dispatch, :target, [1, 2], :instance, ^boundary, ^execution, false} =
             Invocation.plan(bound, [2], :instance, boundary, execution)
  end

  test "resolves function references while preserving the function object identity" do
    execution = execution()
    function = %Function{id: 2, has_prototype: true}
    {reference, execution} = Heap.allocate(execution, :function, callable: function)
    caller = frame()

    assert {:enter, ^function, ^reference, {}, [], :undefined, ^caller, ^execution, false} =
             Invocation.plan(reference, [], :undefined, caller, execution)

    assert Invocation.typeof(reference, execution) == "function"
    assert Invocation.constructable?(reference, execution)
  end

  test "plans declarative Function bind and call without entering interpreter frames" do
    execution = execution()
    caller = frame()
    target = {:host_function, :beam_call}

    call = %Call{
      arguments: [:receiver, 1, 2],
      this: target,
      caller: caller,
      tail?: false,
      execution: execution
    }

    assert {:ok, {:bound_function, ^target, :receiver, [1, 2]}, ^execution} =
             QuickBEAM.VM.Builtin.Function.bind(call)

    assert %Action{
             value: {:dispatch, ^target, [1, 2], :receiver, ^caller, ^execution, true}
           } = QuickBEAM.VM.Builtin.Function.call(%{call | tail?: true})
  end

  defp execution do
    %State{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end

  defp frame do
    function = %Function{id: 0}
    Invocation.new_frame(function, function, [], :undefined, {})
  end
end
