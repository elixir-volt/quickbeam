defmodule QuickBEAM.PoolTest do
  use ExUnit.Case, async: true

  test "basic pool checkout and eval" do
    {:ok, pool} = QuickBEAM.Pool.start_link(size: 2)

    result =
      QuickBEAM.Pool.run(pool, fn rt ->
        {:ok, val} = QuickBEAM.eval(rt, "1 + 2")
        val
      end)

    assert result == 3
  end

  test "pool resets state between checkouts" do
    {:ok, pool} = QuickBEAM.Pool.start_link(size: 1)

    QuickBEAM.Pool.run(pool, fn rt ->
      QuickBEAM.eval(rt, "globalThis.x = 42")
    end)

    result =
      QuickBEAM.Pool.run(pool, fn rt ->
        {:ok, val} = QuickBEAM.eval(rt, "typeof globalThis.x")
        val
      end)

    assert result == "undefined"
  end

  test "pool with init function" do
    {:ok, pool} =
      QuickBEAM.Pool.start_link(
        size: 2,
        init: fn rt -> QuickBEAM.eval(rt, "function greet(n) { return 'hi ' + n }") end
      )

    result =
      QuickBEAM.Pool.run(pool, fn rt ->
        {:ok, val} = QuickBEAM.call(rt, "greet", ["world"])
        val
      end)

    assert result == "hi world"
  end

  test "init function re-runs after reset" do
    {:ok, pool} =
      QuickBEAM.Pool.start_link(
        size: 1,
        init: fn rt -> QuickBEAM.eval(rt, "globalThis.ready = true") end
      )

    QuickBEAM.Pool.run(pool, fn rt ->
      {:ok, true} = QuickBEAM.eval(rt, "ready")
    end)

    result =
      QuickBEAM.Pool.run(pool, fn rt ->
        {:ok, val} = QuickBEAM.eval(rt, "ready")
        val
      end)

    assert result == true
  end

  test "concurrent pool usage" do
    {:ok, pool} = QuickBEAM.Pool.start_link(size: 4)

    tasks =
      for i <- 1..20 do
        Task.async(fn ->
          QuickBEAM.Pool.run(pool, fn rt ->
            {:ok, val} = QuickBEAM.eval(rt, "#{i} * 2")
            val
          end)
        end)
      end

    results = Task.await_many(tasks)
    assert results == Enum.map(1..20, &(&1 * 2))
  end
end
