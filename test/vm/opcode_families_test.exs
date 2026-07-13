defmodule QuickBEAM.VM.OpcodeFamiliesTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Execution, Frame, Function, Heap, Object, Properties}
  alias QuickBEAM.VM.Opcodes.{Control, Locals, Objects, Stack, Values}
  alias QuickBEAM.VM.Opcodes.Invocation, as: CallOpcodes

  test "opcode families publish non-overlapping routing tables" do
    opcodes =
      [CallOpcodes, Control, Locals, Objects, Stack, Values]
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

  test "invocation opcodes decode ordinary, method, and tail-call stacks" do
    execution = execution()

    assert {:invoke, :callable, [:first, :second], :undefined, %Frame{stack: [:rest]}, ^execution,
            false} =
             CallOpcodes.execute(
               :call,
               [2],
               frame([:second, :first, :callable, :rest]),
               execution
             )

    assert {:invoke, :callable, [:argument], :receiver, %Frame{stack: [:rest]}, ^execution, true} =
             CallOpcodes.execute(
               :tail_call_method,
               [1],
               frame([:argument, :callable, :receiver, :rest]),
               execution
             )

    assert {:error, {:invalid_stack, :call}, ^execution} =
             CallOpcodes.execute(:call, [2], frame([:only_one]), execution)
  end

  test "constructor opcodes allocate instances through canonical invocation semantics" do
    execution = execution()
    function = %Function{id: 3, has_prototype: true}
    {constructor, execution} = Heap.allocate(execution, :function, callable: function)
    {prototype, execution} = Heap.allocate(execution)
    {:ok, execution} = Properties.define(constructor, "prototype", prototype, execution)

    assert {:invoke_constructor, ^constructor, [:argument], instance, %Frame{stack: [:rest]},
            execution} =
             CallOpcodes.execute(
               :call_constructor,
               [1],
               frame([:argument, constructor, constructor, :rest]),
               execution
             )

    assert {:ok, %Object{prototype: ^prototype, internal: :constructor_instance}} =
             Heap.fetch_object(execution, instance)
  end

  test "object opcodes return resumable getter and setter actions" do
    execution = execution()
    {object, execution} = Heap.allocate(execution)
    getter = {:builtin, "getter"}
    setter = {:builtin, "setter"}

    {:ok, execution} = Properties.define_accessor(object, "value", :getter, getter, execution)
    {:ok, execution} = Properties.define_accessor(object, "value", :setter, setter, execution)

    assert {:invoke_getter, ^getter, ^object, %Frame{stack: [:rest]}, ^execution} =
             Objects.execute(:get_field, ["value"], frame([object, :rest]), execution)

    assert {:invoke_setter, ^setter, 42, ^object, %Frame{stack: [:rest]}, ^execution} =
             Objects.execute(:put_field, ["value"], frame([42, object, :rest]), execution)
  end

  test "object opcodes allocate arrays and enumerate canonical property order" do
    execution = execution()

    assert {:next, %Frame{stack: [array, :rest]}, execution} =
             Objects.execute(:array_from, [2], frame([2, 1, :rest]), execution)

    assert {:ok, 1} = Properties.get(array, 0, execution)
    assert {:ok, 2} = Properties.get(array, 1, execution)

    assert {:next, %Frame{stack: [{:for_in, [0, 1], 0}]}, ^execution} =
             Objects.execute(:for_in_start, [], frame([array]), execution)
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
