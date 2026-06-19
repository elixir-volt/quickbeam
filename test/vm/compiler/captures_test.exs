defmodule QuickBEAM.VM.Compiler.CapturesTest do
  use QuickBEAM.VM.TestCase, async: true

  alias QuickBEAM.VM.Function
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Captures
  alias QuickBEAM.VM.Interpreter.Context

  test "compiled calls refresh globals before invoking captured closures", %{rt: rt} do
    assert_modes(
      rt,
      ~S<var reads; var f; function reset(value) { f = function() { reads++; return value; }; reads = 0; } reset(42); var result = f(); [result, reads].join("|")>,
      "42|1"
    )
  end

  test "capture runtime helper owns cell and closure reads" do
    assert {:cell, cell_ref} = Captures.ensure_cell(%Context{}, :undefined, 3)
    assert Captures.read_cell(%Context{}, {:cell, cell_ref}, :stale) == 3
    assert :ok = Captures.sync_cell(%Context{}, {:cell, cell_ref}, 5)
    assert Captures.read_cell(%Context{}, {:cell, cell_ref}, :stale) == 5

    function = %Function{closure_vars: [%{closure_type: 0, var_idx: 0, name: "x"}]}
    ctx = %Context{current_func: {:closure, %{{0, 0} => {:cell, cell_ref}}, function}}

    assert Captures.get(ctx, {0, 0}) == 5
    assert Captures.set(ctx, {0, 0}, 8) == 8
    assert Captures.get(ctx, {0, 0}) == 8
  end
end
