defmodule QuickBEAM.VM.Interpreter.GeneratorTest do
  use QuickBEAM.VM.TestCase, async: true

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

  test "caught throwing calls keep global object writes visible", %{rt: rt} do
    assert_modes(
      rt,
      ~S<var first = 0; function f(){ first += 1; throw new Error("boom"); } try { f(); } catch (_) {} var actual = first; [actual, first, globalThis.first].join("|")>,
      "1|1|1"
    )
  end

  test "iterator abrupt completion updates globals before caller catch", %{rt: rt} do
    assert_modes(
      rt,
      ~S<var first = 0; var second = 0; var iter = function*(){ first += 1; throw new Error("boom"); second += 1; }(); var obj = { method([...x]) {} }; try { obj.method(iter); } catch (_) {} iter.next(); [first, second, globalThis.first].join("|")>,
      "1|0|1"
    )
  end

  test "compiled generators with cleanup fall back to interpreter semantics", %{rt: rt} do
    assert_modes(
      rt,
      ~S"function* g(){ try { yield 1; } finally { yield 2; } } var it = g(); [it.next().value, it.return(9).value, it.next().value].join('|')",
      "1|2|9"
    )
  end
end
