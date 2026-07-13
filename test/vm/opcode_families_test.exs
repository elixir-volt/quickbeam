defmodule QuickBEAM.VM.OpcodeFamiliesTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Execution, Frame, Function, Heap, Object, Properties}
  alias QuickBEAM.VM.Opcodes.{Control, Locals, Stack, Values}

  test "opcode families publish non-overlapping routing tables" do
    opcodes =
      [Control, Locals, Stack, Values]
      |> Enum.flat_map(& &1.opcodes())

    assert length(opcodes) == MapSet.size(MapSet.new(opcodes))
  end

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

  test "control opcodes return explicit branch, return, throw, and await actions" do
    execution = execution()

    assert {:run, %Frame{pc: 9, stack: [:rest]}, ^execution} =
             Control.execute(:if_true, [9], frame([true, :rest]), execution)

    assert {:next, %Frame{stack: [{:catch, 12}, :rest]}, ^execution} =
             Control.execute(:catch, [12], frame([:rest]), execution)

    assert {:return, 42, ^execution} = Control.execute(:return, [], frame([42]), execution)

    assert {:throw, "boom", %Frame{stack: [:rest]}, ^execution} =
             Control.execute(:throw, [], frame(["boom", :rest]), execution)

    assert {:await_immediate, {:ok, 7}, %Frame{stack: [:rest]}, ^execution} =
             Control.execute(:await, [], frame([7, :rest]), execution)
  end

  test "local opcodes preserve mutable closure-cell identity" do
    execution = %{execution() | cells: %{0 => 10}, next_cell_id: 1}
    frame = %{frame([20]) | locals: {{:cell, 0}}}

    assert {:next, %Frame{locals: {{:cell, 0}}, stack: []}, execution} =
             Locals.execute(:put_loc, [0], frame, execution)

    assert execution.cells == %{0 => 20}

    assert {:next, %Frame{stack: [20]}, ^execution} =
             Locals.execute(:get_loc, [0], %{frame | stack: []}, execution)

    uninitialized = %{frame | locals: {:uninitialized}, stack: []}

    assert {:throw, {:reference_error, 0}, ^uninitialized, ^execution} =
             Locals.execute(:get_loc_check, [0], uninitialized, execution)
  end

  test "closure opcodes promote captured slots into owner-local cells" do
    child = %Function{
      id: 2,
      closure_vars: [%{closure_type: 0, var_idx: 0}],
      instructions: {{0, []}}
    }

    parent = %Function{
      id: 1,
      arg_count: 0,
      constants: [child],
      instructions: {{0, []}}
    }

    frame = %Frame{function: parent, callable: parent, locals: {7}, args: {}, stack: []}

    assert {:next, %Frame{locals: {{:cell, 0}}, stack: [reference]}, execution} =
             Locals.execute(:fclosure, [0], frame, execution())

    assert execution.cells == %{0 => 7}

    assert {:ok, %Object{callable: {:closure, ^child, {{:cell, 0}}}}} =
             Heap.fetch_object(execution, reference)
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
