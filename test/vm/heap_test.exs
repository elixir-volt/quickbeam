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

  test "tracks array length while preserving sparse entries" do
    execution = execution()
    {array, execution} = Heap.allocate(execution, :array)
    {:ok, execution} = Heap.put(execution, array, 2, "third")

    assert {:ok, 3} = Heap.get(execution, array, "length")
    assert {:ok, :undefined} = Heap.get(execution, array, 0)
    assert {:ok, "third"} = Heap.get(execution, array, 2)
    assert {:ok, [:undefined, :undefined, "third"]} = Export.value(array, execution)
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
