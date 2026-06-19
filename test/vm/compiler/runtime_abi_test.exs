defmodule QuickBEAM.VM.Compiler.RuntimeABITest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.RuntimeABI
  alias QuickBEAM.VM.{Function, Heap}
  alias QuickBEAM.VM.Interpreter.Context

  setup do
    Heap.reset()
    :ok
  end

  test "get_field resolves atom keys from supplied context" do
    Heap.put_atoms({"ambient"})
    object = Heap.wrap(%{"actual" => 7, "ambient" => 9})
    ctx = %Context{atoms: {"actual"}}

    assert RuntimeABI.get_field(ctx, object, 0) == 7
  end

  test "capture helpers read cells through the ABI" do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, 11)

    function = %Function{closure_vars: [%{closure_type: 0, var_idx: 0, name: "x"}]}
    ctx = %Context{current_func: {:closure, %{{0, 0} => {:cell, cell_ref}}, function}}

    assert RuntimeABI.get_capture(ctx, {0, 0}) == 11
    assert :ok = RuntimeABI.sync_capture_cell(ctx, {:cell, cell_ref}, 12)
    assert RuntimeABI.get_capture(ctx, {0, 0}) == 12
  end

  test "class and object helpers are routed through the ABI" do
    object = RuntimeABI.new_object(%Context{})

    assert ^object = RuntimeABI.define_field(%Context{atoms: {"answer"}}, object, "answer", 42)
    assert RuntimeABI.get_field(%Context{}, object, "answer") == 42

    brand = make_ref()
    assert :ok = RuntimeABI.add_brand(%Context{}, object, brand)
    assert :ok = RuntimeABI.check_brand(%Context{}, object, brand)
  end
end
