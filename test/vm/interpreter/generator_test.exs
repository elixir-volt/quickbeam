defmodule QuickBEAM.VM.Interpreter.GeneratorTest do
  use QuickBEAM.VMCase, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Context

  test "sync generator next restores previous context", %{rt: rt} do
    previous = %Context{globals: %{"sentinel" => 1}}
    Heap.put_ctx(previous)

    assert beam!(rt, "function* g(){ yield 1; } let it = g(); it.next().value") == 1
    assert %Context{globals: %{"sentinel" => 1}} = Heap.get_ctx()
  end

  test "sync generator next clears context when no previous context exists", %{rt: rt} do
    Heap.put_ctx(nil)

    assert beam!(rt, "function* g(){ yield 1; } let it = g(); it.next().value") == 1
    assert Heap.get_ctx() == nil
  end
end
