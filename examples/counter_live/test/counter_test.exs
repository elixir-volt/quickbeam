defmodule CounterLive.CounterTest do
  use ExUnit.Case, async: true

  @script Path.expand("../priv/js/counter.ts", __DIR__)

  setup do
    {:ok, ctx} = QuickBEAM.Context.start_link(
      pool: CounterLive.JSPool,
      script: @script,
      apis: false
    )

    %{ctx: ctx}
  end

  test "starts at zero", %{ctx: ctx} do
    {:ok, count} = QuickBEAM.Context.call(ctx, "getCount")
    assert count == 0
  end

  test "increment", %{ctx: ctx} do
    {:ok, 1} = QuickBEAM.Context.call(ctx, "increment")
    {:ok, 2} = QuickBEAM.Context.call(ctx, "increment")
    {:ok, count} = QuickBEAM.Context.call(ctx, "getCount")
    assert count == 2
  end

  test "decrement", %{ctx: ctx} do
    {:ok, -1} = QuickBEAM.Context.call(ctx, "decrement")
    {:ok, -2} = QuickBEAM.Context.call(ctx, "decrement")
    {:ok, count} = QuickBEAM.Context.call(ctx, "getCount")
    assert count == -2
  end

  test "increment by amount", %{ctx: ctx} do
    {:ok, 10} = QuickBEAM.Context.call(ctx, "increment", [10])
    {:ok, 15} = QuickBEAM.Context.call(ctx, "increment", [5])
    assert {:ok, 15} == QuickBEAM.Context.call(ctx, "getCount")
  end

  test "reset", %{ctx: ctx} do
    {:ok, _} = QuickBEAM.Context.call(ctx, "increment", [42])
    {:ok, 0} = QuickBEAM.Context.call(ctx, "reset")
    assert {:ok, 0} == QuickBEAM.Context.call(ctx, "getCount")
  end

  test "separate contexts have independent state" do
    {:ok, ctx1} = QuickBEAM.Context.start_link(
      pool: CounterLive.JSPool,
      script: @script,
      apis: false
    )

    {:ok, ctx2} = QuickBEAM.Context.start_link(
      pool: CounterLive.JSPool,
      script: @script,
      apis: false
    )

    {:ok, _} = QuickBEAM.Context.call(ctx1, "increment", [100])
    {:ok, _} = QuickBEAM.Context.call(ctx2, "increment", [1])

    assert {:ok, 100} == QuickBEAM.Context.call(ctx1, "getCount")
    assert {:ok, 1} == QuickBEAM.Context.call(ctx2, "getCount")
  end

  test "context cleans up when caller exits" do
    test_pid = self()

    {spawned_pid, monitor_ref} =
      spawn_monitor(fn ->
        {:ok, ctx} = QuickBEAM.Context.start_link(
          pool: CounterLive.JSPool,
          script: @script,
          apis: false
        )

        send(test_pid, {:ctx, ctx})
        Process.sleep(:infinity)
      end)

    ctx =
      receive do
        {:ctx, pid} -> pid
      after
        2000 -> flunk("timeout waiting for context")
      end

    Process.exit(spawned_pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^spawned_pid, _} -> :ok
    after
      1000 -> flunk("process didn't exit")
    end

    Process.sleep(50)
    refute Process.alive?(ctx)
  end
end
