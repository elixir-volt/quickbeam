defmodule QuickBEAM.VM.InvocationTest do
  use QuickBEAM.VMCase, async: true

  alias QuickBEAM.VM.{Heap, Invocation}

  test "invoke depth is restored when compiled invocation throws", %{rt: rt} do
    {:ok, fun} =
      QuickBEAM.eval(rt, ~S|(function(){ throw new Error("boom") })|, mode: :beam_compiler)

    Process.put(:qb_gc_needed, true)

    assert {:js_throw, {:obj, _}} = catch_throw(Invocation.invoke(fun, []))
    assert Heap.get_invoke_depth() == 0
    refute Heap.gc_needed?()
  end

  test "method invocation depth is restored when receiver call throws", %{rt: rt} do
    {:ok, fun} =
      QuickBEAM.eval(rt, ~S|(function(){ throw new Error("boom") })|, mode: :beam_compiler)

    receiver = Heap.wrap(%{})
    Process.put(:qb_gc_needed, true)

    assert {:js_throw, {:obj, _}} =
             catch_throw(Invocation.invoke_with_receiver(fun, [], receiver))

    assert Heap.get_invoke_depth() == 0
    refute Heap.gc_needed?()
  end
end
