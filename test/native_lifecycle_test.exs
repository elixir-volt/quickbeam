defmodule QuickBEAM.NativeLifecycleTest do
  use ExUnit.Case, async: false

  @tag timeout: 120_000
  test "serializes concurrent runtime startup, explicit shutdown, and destruction" do
    tasks =
      for worker <- 1..8 do
        Task.async(fn ->
          for iteration <- 1..15 do
            {:ok, runtime} = QuickBEAM.start()
            expected = worker + iteration
            assert {:ok, ^expected} = QuickBEAM.eval(runtime, "#{worker} + #{iteration}")
            assert :ok = QuickBEAM.stop(runtime)
          end
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 120_000), &is_list/1)
  end

  @tag timeout: 120_000
  test "concurrent native stop calls join each worker exactly once" do
    runtime = QuickBEAM.Native.start_runtime(self(), %{})

    runtime_results =
      for _caller <- 1..32 do
        Task.async(fn -> QuickBEAM.Native.stop_runtime(runtime) end)
      end
      |> Task.await_many(120_000)

    assert runtime_results == List.duplicate(:ok, 32)

    pool = QuickBEAM.Native.pool_start(%{})

    pool_results =
      for _caller <- 1..32 do
        Task.async(fn -> QuickBEAM.Native.pool_stop(pool) end)
      end
      |> Task.await_many(120_000)

    assert pool_results == List.duplicate(:ok, 32)
  end

  @tag timeout: 120_000
  test "resource destruction joins runtime workers when owners exit without stopping" do
    monitors =
      for _iteration <- 1..200 do
        spawn_monitor(fn ->
          _resource = QuickBEAM.Native.start_runtime(self(), %{})
          :ok
        end)
        |> elem(1)
      end

    Enum.each(monitors, fn monitor ->
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 120_000
    end)
  end

  @tag timeout: 120_000
  test "resource destruction joins context-pool workers when owners exit" do
    monitors =
      for _iteration <- 1..100 do
        spawn_monitor(fn ->
          resource = QuickBEAM.Native.pool_start(%{})

          for context_id <- 1..3 do
            _ref = QuickBEAM.Native.pool_create_context(resource, context_id, self(), 0, 0)
          end

          :ok
        end)
        |> elem(1)
      end

    Enum.each(monitors, fn monitor ->
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 120_000
    end)
  end
end
