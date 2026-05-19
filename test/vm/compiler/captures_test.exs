defmodule QuickBEAM.VM.Compiler.CapturesTest do
  use QuickBEAM.VM.TestCase, async: true

  test "compiled calls refresh globals before invoking captured closures", %{rt: rt} do
    assert_modes(
      rt,
      ~S<var reads; var f; function reset(value) { f = function() { reads++; return value; }; reads = 0; } reset(42); var result = f(); [result, reads].join("|")>,
      "42|1"
    )
  end
end
