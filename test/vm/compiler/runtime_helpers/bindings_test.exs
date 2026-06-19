defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.BindingsTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.{Function, Heap}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings
  alias QuickBEAM.VM.Interpreter.Context

  setup do
    Heap.reset()
    :ok
  end

  test "global binding reads use supplied compiled context" do
    ctx = %Context{atoms: {"answer", "missing"}, globals: %{"answer" => 42}}

    assert Bindings.get_var(ctx, 0) == 42
    assert Bindings.get_var_undef(ctx, 1) == :undefined
    assert Bindings.delete_var(ctx, 1)
  end

  test "variable refs read and write closure cells" do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, 1)

    function = %Function{closure_vars: [%{closure_type: 0, var_idx: 0, name: "x"}]}

    ctx = %Context{
      atoms: {"x"},
      current_func: {:closure, %{{0, 0} => {:cell, cell_ref}}, function}
    }

    assert Bindings.get_var_ref(ctx, 0) == 1
    assert :ok = Bindings.put_var_ref(ctx, 0, 2)
    assert Bindings.get_var_ref(ctx, 0) == 2
    assert Bindings.set_var_ref(ctx, 0, 3) == 3
    assert Bindings.get_var_ref(ctx, 0) == 3
  end

  test "reference helpers preserve global and object writes" do
    ctx = %Context{globals: %{"globalThis" => :undefined}}
    object = Heap.wrap(%{"x" => 1})

    assert Bindings.get_ref_value(ctx, "x", object) == 1
    assert ^ctx = Bindings.put_ref_value(ctx, 2, "x", object)
    assert Bindings.get_ref_value(ctx, "x", object) == 2

    updated = Bindings.put_ref_value(ctx, 9, "g", {:global_ref, "g"})
    assert Bindings.get_var_undef(updated, "g") == 9
  end
end
