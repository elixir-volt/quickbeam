defmodule QuickBEAM.VM.HeapTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Execution, Export, Heap}

  test "resolves inherited properties through the prototype chain" do
    execution = execution()
    {prototype, execution} = Heap.allocate(execution)
    {:ok, execution} = Heap.define(execution, prototype, "inherited", 42)
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)

    assert {:ok, 42} = Heap.get(execution, object, "inherited")
    assert {:ok, :undefined} = Heap.get(execution, object, "missing")
  end

  test "bulk dense arrays preserve sequential allocation and exact accounting" do
    values = ["first", :undefined, 42]
    {bulk, bulk_execution} = Heap.allocate_array(execution(), values)

    {sequential, sequential_execution} = Heap.allocate(execution(), :array)

    sequential_execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(sequential_execution, fn {value, index}, execution ->
        {:ok, execution} = Heap.define(execution, sequential, index, value)
        execution
      end)

    assert bulk_execution.memory_used == sequential_execution.memory_used

    assert Heap.fetch_object(bulk_execution, bulk) ==
             Heap.fetch_object(sequential_execution, sequential)

    assert {:ok, values} == Export.value(bulk, bulk_execution)
    assert {:ok, %{property_order: []}} = Heap.fetch_object(bulk_execution, bulk)
  end

  test "stores default array descriptors compactly and retains exceptional descriptors" do
    {array, execution} = Heap.allocate(execution(), :array)
    {:ok, execution} = Heap.define(execution, array, 0, :undefined)
    {:ok, execution} = Heap.define(execution, array, 1, "fixed", writable: false)

    assert {:ok, object} = Heap.fetch_object(execution, array)
    assert object.properties[0] == {:undefined}
    assert %QuickBEAM.VM.Property{value: "fixed", writable: false} = object.properties[1]

    assert {:ok, %QuickBEAM.VM.Property{value: :undefined}} =
             Heap.own_property(execution, array, 0)

    assert {:ok, :undefined} = Heap.get(execution, array, 0)
    assert {:error, {:property_not_writable, 1}} = Heap.put(execution, array, 1, "changed")
  end

  test "tracks array length while preserving sparse entries" do
    execution = execution()
    {array, execution} = Heap.allocate(execution, :array)
    {:ok, execution} = Heap.put(execution, array, 2, "third")

    assert {:ok, 3} = Heap.get(execution, array, "length")
    assert {:ok, :undefined} = Heap.get(execution, array, 0)
    assert {:ok, "third"} = Heap.get(execution, array, 2)
    assert {:ok, [:undefined, :undefined, "third"]} = Export.value(array, execution)
  end

  test "shrinks array length without materializing an enumerable length property" do
    execution = execution()
    {array, execution} = Heap.allocate(execution, :array)
    {:ok, execution} = Heap.put(execution, array, 0, "first")
    {:ok, execution} = Heap.put(execution, array, 2, "third")
    {:ok, execution} = Heap.put(execution, array, "length", 1)

    assert {:ok, 1} = Heap.get(execution, array, "length")
    assert {:ok, :undefined} = Heap.get(execution, array, 2)
    assert {:ok, [0]} = Heap.own_keys(execution, array)
  end

  test "rejects writes shadowing an inherited non-writable property" do
    execution = execution()
    {prototype, execution} = Heap.allocate(execution)
    {:ok, execution} = Heap.define(execution, prototype, "fixed", 1, writable: false)
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)

    assert {:error, {:property_not_writable, "fixed"}} =
             Heap.put(execution, object, "fixed", 2)

    assert {:ok, 1} = Heap.get(execution, object, "fixed")
  end

  test "orders integer keys before string keys and preserves string insertion order" do
    execution = execution()
    {object, execution} = Heap.allocate(execution)
    {:ok, execution} = Heap.put(execution, object, "second", 2)
    {:ok, execution} = Heap.put(execution, object, 4, 4)
    {:ok, execution} = Heap.put(execution, object, "first", 1)
    {:ok, execution} = Heap.put(execution, object, 1, 1)

    assert {:ok, [1, 4, "second", "first"]} = Heap.own_keys(execution, object)
    assert {:ok, %{property_order: ["second", "first"]}} = Heap.fetch_object(execution, object)
  end

  test "honors writable and configurable descriptor flags" do
    execution = execution()
    {object, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Heap.define(execution, object, "fixed", 1, writable: false, configurable: false)

    assert {:error, {:property_not_writable, "fixed"}} = Heap.put(execution, object, "fixed", 2)
    assert {:ok, false, ^execution} = Heap.delete(execution, object, "fixed")
  end

  test "rejects cyclic owner-local objects during result conversion" do
    execution = execution()
    {object, execution} = Heap.allocate(execution)
    {:ok, execution} = Heap.put(execution, object, "self", object)

    assert {:error, {:cyclic_result, object.id}} == Export.value(object, execution)
  end

  defp execution do
    %Execution{atoms: {}, max_stack_depth: 10, remaining_steps: 10, step_limit: 10}
  end
end
