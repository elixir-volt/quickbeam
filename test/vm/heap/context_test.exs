defmodule QuickBEAM.VM.Heap.ContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.GlobalEnvironment
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

  test "fast context preserves full interpreter state when reconstructed" do
    ctx = %Context{
      globals: %{"g" => 1},
      catch_stack: [{12, [:marker]}],
      runtime_pid: self(),
      gas: 123,
      trace_enabled: true
    }

    InvokeContext.put_fast_ctx(ctx)

    assert %Context{
             globals: %{"g" => 1},
             catch_stack: [{12, [:marker]}],
             runtime_pid: pid,
             gas: 123,
             trace_enabled: true,
             pd_synced: true
           } = Heap.get_ctx()

    assert pid == self()
  end

  test "persistent globals invalidate base globals cache" do
    Heap.put_global_cache(%{"builtin" => 1})
    assert GlobalEnvironment.base_globals()["user"] == nil

    Heap.put_persistent_globals(%{"user" => 2})

    assert GlobalEnvironment.base_globals()["user"] == 2
  end
end
