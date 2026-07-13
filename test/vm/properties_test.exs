defmodule QuickBEAM.VM.PropertiesTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Builtins, Execution, Heap, Invocation, Properties, Reference}

  test "returns explicit getter and setter actions with the original receiver" do
    execution = execution()
    {prototype, execution} = Heap.allocate(execution)
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    getter = {:builtin, "getter"}
    setter = {:builtin, "setter"}

    {:ok, execution} =
      Properties.define_accessor(prototype, "value", :getter, getter, execution)

    {:ok, execution} =
      Properties.define_accessor(prototype, "value", :setter, setter, execution)

    assert {:ok, {:accessor, ^getter, ^object}} = Properties.get(object, "value", execution)
    assert {:error, {:invoke_setter, ^setter}} = Properties.put(object, "value", 42, execution)
  end

  test "resolves primitive and callable properties through intrinsic prototypes" do
    execution = Builtins.install(execution())
    {callable, execution} = Heap.allocate(execution, :function, callable: {:builtin, "callable"})

    assert {:ok, %Reference{} = bind} = Properties.get(callable, "bind", execution)
    assert Invocation.callable?(bind, execution)
    assert {:ok, "bind"} = Properties.get(bind, "name", execution)
    assert {:ok, 2} = Properties.get("😀", "length", execution)
    assert {:ok, <<0xED, 0xA0, 0xBD>>} = Properties.get("😀", 0, execution)

    assert {:ok, %Reference{} = to_string} = Properties.get(42, "toString", execution)
    assert Invocation.callable?(to_string, execution)
    assert {:ok, "toString"} = Properties.get(to_string, "name", execution)
  end

  test "centralizes descriptors, enumeration, and prototype operations" do
    execution = execution()
    {prototype, execution} = Heap.allocate(execution)
    {object, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Properties.define(object, "hidden", 1, execution, enumerable: false)

    {:ok, execution} = Properties.define(object, 2, 2, execution)
    {:ok, execution} = Properties.set_prototype(object, prototype, execution)

    assert {:ok, [2]} = Properties.enumerable_keys(object, execution)
    assert {:ok, ["2", "hidden"]} = Properties.own_property_names(object, execution)
    assert {:ok, ^prototype} = Properties.prototype(object, execution)
    assert Properties.prototype_chain_contains?(object, prototype, execution)
    assert Properties.has_property?(object, "hidden", execution)
  end

  defp execution do
    %Execution{atoms: {}, max_stack_depth: 10, remaining_steps: 100, step_limit: 100}
  end
end
