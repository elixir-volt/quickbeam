defmodule QuickBEAM.VM.Heap.ContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.GlobalEnv
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  setup do
    Heap.reset()
    :ok
  end

  test "put_ctx clears fast context when clearing or replacing full context" do
    InvokeContext.put_fast_ctx(%Context{globals: %{"stale" => 1}})
    assert %Context{globals: %{"stale" => 1}} = Heap.get_ctx()

    Heap.put_ctx(nil)
    assert Heap.get_ctx() == nil

    InvokeContext.put_fast_ctx(%Context{globals: %{"stale" => 1}})
    Heap.put_ctx(%Context{globals: %{"fresh" => 2}})
    assert %Context{globals: %{"fresh" => 2}} = Heap.get_ctx()
    assert InvokeContext.fast_ctx() == :__qb_missing__
  end

  test "persistent globals invalidate base globals cache" do
    Heap.put_global_cache(%{"builtin" => 1})
    assert GlobalEnv.base_globals()["user"] == nil

    Heap.put_persistent_globals(%{"user" => 2})

    assert GlobalEnv.base_globals()["user"] == 2
  end
end
