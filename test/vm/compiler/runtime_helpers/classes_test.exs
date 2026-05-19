defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.ClassesTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.{Classes, Properties}
  alias QuickBEAM.VM.Interpreter.Context

  setup do
    Heap.reset()
    :ok
  end

  test "brand helpers add and validate private brands" do
    object = Properties.new_object(%Context{})
    brand = make_ref()

    assert :ok = Classes.add_brand(%Context{}, object, brand)
    assert :ok = Classes.check_brand(%Context{}, object, brand)
  end

  test "method helpers install methods by property name" do
    target = Properties.new_object(%Context{})
    method = {:builtin, "m", fn _, _ -> :ok end}

    assert ^target = Classes.define_method(%Context{}, target, method, "m", 0)
    assert Properties.get_field(%Context{}, target, "m") == method
  end
end
