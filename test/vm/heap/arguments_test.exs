defmodule QuickBEAM.VM.Heap.ArgumentsTest do
  use QuickBEAM.VMCase, async: true

  test "sloppy arguments callee resolves to the current function", %{rt: rt} do
    assert beam!(rt, """
           (function () {
             return typeof arguments.callee;
           })();
           """) == "function"
  end

  test "sloppy arguments indices alias formal parameter bindings", %{rt: rt} do
    assert_modes(
      rt,
      ~S|(function(a, b, c) { a = b; b = c; c = 1; return [arguments[0], arguments[1], arguments[2]].join(","); })(1, 2, 3)|,
      "2,3,1"
    )
  end

  test "deleting mapped arguments disconnects parameter aliases", %{rt: rt} do
    assert_modes(
      rt,
      ~S|(function(a) { delete arguments[0]; a = 7; return String(arguments[0]); })(1)|,
      "undefined"
    )
  end

  test "duplicate sloppy parameter names map only the last occurrence", %{rt: rt} do
    assert_modes(
      rt,
      ~S|(function(a, a) { a = 7; return [arguments[0], arguments[1]].join(","); })(1, 2)|,
      "1,7"
    )
  end
end
