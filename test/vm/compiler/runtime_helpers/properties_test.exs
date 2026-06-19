defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.PropertiesTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Properties
  alias QuickBEAM.VM.Interpreter.Context

  setup do
    Heap.reset()
    :ok
  end

  test "property helpers read, write, and define fields" do
    ctx = %Context{atoms: {"answer"}}
    object = Properties.new_object(ctx)

    assert ^object = Properties.define_field(ctx, object, "answer", 41)
    assert Properties.get_field(ctx, object, "answer") == 41
    assert :ok = Properties.put_field(ctx, object, "answer", 42)
    assert Properties.get_field(ctx, object, "answer") == 42
  end

  test "delete_property honors global object built-in deletion rules" do
    global = Properties.new_object(%Context{})

    ctx = %Context{
      this: global,
      globals: %{
        "globalThis" => global,
        "Object" => {:builtin, "Object", fn _, _ -> :undefined end}
      }
    }

    assert Properties.delete_property(ctx, global, "Object")
  end

  test "array and object literal helpers preserve descriptors" do
    object = Properties.array_from(%Context{}, ["a", "b"])

    assert Properties.get_array_el(%Context{}, object, 0) == "a"
    assert :ok = Properties.put_array_el(%Context{}, object, 1, "c")
    assert Properties.get_array_el(%Context{}, object, 1) == "c"
  end
end
