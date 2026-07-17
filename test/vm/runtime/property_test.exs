defmodule QuickBEAM.VM.Runtime.PropertyTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Builtin.Runtime, as: BuiltinRuntime
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference

  test "returns explicit getter and setter actions with the original receiver" do
    execution = execution()
    {prototype, execution} = Heap.allocate(execution)
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    getter = {:builtin, "getter"}
    setter = {:builtin, "setter"}

    {:ok, execution} =
      Property.define_accessor(prototype, "value", :getter, getter, execution)

    {:ok, execution} =
      Property.define_accessor(prototype, "value", :setter, setter, execution)

    assert {:ok, {:accessor, ^getter, ^object}} = Property.get(object, "value", execution)
    assert {:error, {:invoke_setter, ^setter}} = Property.put(object, "value", 42, execution)
  end

  test "resolves primitive and callable properties through intrinsic prototypes" do
    execution = BuiltinRuntime.install(execution())
    {callable, execution} = Heap.allocate(execution, :function, callable: {:builtin, "callable"})

    assert {:ok, %Reference{} = bind} = Property.get(callable, "bind", execution)
    assert Invocation.callable?(bind, execution)
    assert {:ok, "bind"} = Property.get(bind, "name", execution)
    assert {:ok, 2} = Property.get("😀", "length", execution)
    assert {:ok, <<0xED, 0xA0, 0xBD>>} = Property.get("😀", 0, execution)

    assert {:ok, %Reference{} = to_string} = Property.get(42, "toString", execution)
    assert Invocation.callable?(to_string, execution)
    assert {:ok, "toString"} = Property.get(to_string, "name", execution)
  end

  test "centralizes descriptors, enumeration, and prototype operations" do
    execution = execution()
    {prototype, execution} = Heap.allocate(execution)
    {object, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Property.define(object, "hidden", 1, execution, enumerable: false)

    {:ok, execution} = Property.define(object, 2, 2, execution)
    {:ok, execution} = Property.set_prototype(object, prototype, execution)

    assert {:ok, [2]} = Property.enumerable_keys(object, execution)
    assert {:ok, ["2", "hidden"]} = Property.own_property_names(object, execution)
    assert {:ok, ^prototype} = Property.prototype(object, execution)
    assert Property.prototype_chain_contains?(object, prototype, execution)
    assert Property.has_property?(object, "hidden", execution)
  end

  defp execution do
    %State{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end
end
