defmodule QuickBEAM.VM.OpcodeFamiliesTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Execution, Frame, Function, Heap, Properties}
  alias QuickBEAM.VM.Opcodes.{Stack, Values}

  test "stack opcodes transform explicit frames without advancing the program counter" do
    execution = execution()
    frame = frame([:a, :b, :c])

    assert {:next, %Frame{pc: 4, stack: [:a, :b, :a, :b, :c]}, ^execution} =
             Stack.execute(:dup2, [], frame, execution)

    assert {:next, %Frame{stack: [:b, :a, :c]}, ^execution} =
             Stack.execute(:swap, [], frame, execution)

    assert {:next, %Frame{stack: [20, :a, :b, :c]}, ^execution} =
             Stack.execute(:push_const, [1], frame, execution)

    assert {:next, %Frame{stack: [{:bigint, 9}, :a, :b, :c]}, ^execution} =
             Stack.execute(:push_bigint_i32, [9], frame, execution)
  end

  test "value opcodes delegate arithmetic, coercion, and post-update semantics" do
    execution = execution()

    assert {:next, %Frame{stack: [7, :rest]}, ^execution} =
             Values.execute(:add, [], frame([4, 3, :rest]), execution)

    assert {:next, %Frame{stack: [true, :rest]}, ^execution} =
             Values.execute(:lnot, [], frame([0, :rest]), execution)

    assert {:next, %Frame{stack: [4, 3, :rest]}, ^execution} =
             Values.execute(:post_inc, [], frame([3, :rest]), execution)

    assert {:throw, {:type_error, :cannot_convert_to_object}, %Frame{}, ^execution} =
             Values.execute(:to_object, [], frame([nil]), execution)
  end

  test "value opcodes share canonical callable and prototype semantics" do
    execution = execution()
    function = %Function{id: 1, has_prototype: true}
    {constructor, execution} = Heap.allocate(execution, :function, callable: function)
    {prototype, execution} = Heap.allocate(execution)
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    {:ok, execution} = Properties.define(constructor, "prototype", prototype, execution)

    assert {:next, %Frame{stack: [true]}, ^execution} =
             Values.execute(:is_function, [], frame([constructor]), execution)

    assert {:next, %Frame{stack: [true]}, ^execution} =
             Values.execute(:instanceof, [], frame([constructor, object]), execution)
  end

  defp execution do
    %Execution{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end

  defp frame(stack) do
    function = %Function{id: 0, constants: [10, 20], instructions: {{0, []}}}

    %Frame{
      function: function,
      callable: function,
      locals: {},
      args: {},
      pc: 4,
      stack: stack
    }
  end
end
