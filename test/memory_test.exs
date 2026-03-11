defmodule QuickBEAM.MemoryTest do
  use ExUnit.Case

  @tag :memory
  describe "QuickJS memory usage" do
    test "memory_usage returns QuickJS internals", %{} do
      {:ok, rt} = QuickBEAM.start()
      usage = QuickBEAM.memory_usage(rt)

      assert is_integer(usage.malloc_size)
      assert usage.malloc_size > 0
      assert is_integer(usage.atom_count)
      assert usage.atom_count > 0
      assert is_integer(usage.obj_count)

      QuickBEAM.stop(rt)
    end

    test "memory_usage grows with allocations", %{} do
      {:ok, rt} = QuickBEAM.start()
      before = QuickBEAM.memory_usage(rt)

      QuickBEAM.eval(rt, """
      globalThis.bigArray = [];
      for (let i = 0; i < 10000; i++) bigArray.push({x: i, y: 'hello'});
      """)

      after_alloc = QuickBEAM.memory_usage(rt)
      assert after_alloc.malloc_size > before.malloc_size
      assert after_alloc.obj_count > before.obj_count

      QuickBEAM.stop(rt)
    end

    test "memory stabilizes across reset cycles", %{} do
      {:ok, rt} = QuickBEAM.start()

      # First cycle establishes the pool size
      QuickBEAM.eval(rt, """
      globalThis.data = [];
      for (let i = 0; i < 5000; i++) data.push({x: i});
      """)

      QuickBEAM.reset(rt)
      first_reset = QuickBEAM.memory_usage(rt)

      # Subsequent cycles should not grow
      for _ <- 1..5 do
        QuickBEAM.eval(rt, """
        globalThis.data = [];
        for (let i = 0; i < 5000; i++) data.push({x: i});
        """)

        QuickBEAM.reset(rt)
      end

      after_cycles = QuickBEAM.memory_usage(rt)

      growth = after_cycles.malloc_size - first_reset.malloc_size

      assert growth <= 0,
             "Memory grew by #{growth} bytes across 5 reset cycles (pool should be stable)"

      QuickBEAM.stop(rt)
    end

    test "eval cycles don't accumulate memory", %{} do
      {:ok, rt} = QuickBEAM.start()

      # Warm up
      for _ <- 1..10, do: QuickBEAM.eval(rt, "JSON.parse(JSON.stringify({a: 1}))")
      before = QuickBEAM.memory_usage(rt)

      for _ <- 1..1000 do
        QuickBEAM.eval(rt, "JSON.parse(JSON.stringify({a: [1,2,3], b: 'hello world'}))")
      end

      after_loop = QuickBEAM.memory_usage(rt)
      growth = after_loop.malloc_size - before.malloc_size

      # QuickJS GC should keep memory stable — allow 100KB growth max
      assert growth < 100 * 1024,
             "QuickJS memory grew by #{div(growth, 1024)}KB over 1000 eval cycles"

      QuickBEAM.stop(rt)
    end
  end

  describe "BEAM memory stability" do
    test "eval cycle does not leak" do
      {:ok, rt} = QuickBEAM.start()

      # Warm up
      for _ <- 1..10, do: QuickBEAM.eval(rt, "1 + 1")
      :erlang.garbage_collect()
      Process.sleep(50)

      mem_before = :erlang.memory(:total)

      for _ <- 1..1000 do
        QuickBEAM.eval(rt, "1 + 1")
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before
      # Allow up to 512KB growth (BEAM overhead, caches, etc.)
      assert growth < 512 * 1024,
             "Memory grew by #{div(growth, 1024)}KB over 1000 evals"

      QuickBEAM.stop(rt)
    end

    test "TextEncoder cycle does not leak" do
      {:ok, rt} = QuickBEAM.start()

      for _ <- 1..10, do: QuickBEAM.eval(rt, "new TextEncoder().encode('warmup')")
      :erlang.garbage_collect()
      Process.sleep(50)

      mem_before = :erlang.memory(:total)

      for _ <- 1..1000 do
        QuickBEAM.eval(rt, "new TextEncoder().encode('hello world test string')")
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 512 * 1024,
             "Memory grew by #{div(growth, 1024)}KB over 1000 TextEncoder evals"

      QuickBEAM.stop(rt)
    end

    test "btoa/atob cycle does not leak" do
      {:ok, rt} = QuickBEAM.start()

      for _ <- 1..10, do: QuickBEAM.eval(rt, "atob(btoa('warmup'))")
      :erlang.garbage_collect()
      Process.sleep(50)

      mem_before = :erlang.memory(:total)

      for _ <- 1..1000 do
        QuickBEAM.eval(rt, "atob(btoa('The quick brown fox jumps over the lazy dog'))")
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 512 * 1024,
             "Memory grew by #{div(growth, 1024)}KB over 1000 atob/btoa evals"

      QuickBEAM.stop(rt)
    end

    test "Beam.call cycle does not leak" do
      {:ok, rt} = QuickBEAM.start(handlers: %{"test" => fn args -> {:ok, args} end})

      for _ <- 1..10, do: QuickBEAM.eval(rt, "await Beam.call('test', 42)")
      :erlang.garbage_collect()
      Process.sleep(50)

      mem_before = :erlang.memory(:total)

      for _ <- 1..1000 do
        QuickBEAM.eval(rt, "await Beam.call('test', 'hello')")
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 1024 * 1024,
             "Memory grew by #{div(growth, 1024)}KB over 1000 beam.call evals"

      QuickBEAM.stop(rt)
    end

    test "reset cycle does not leak" do
      {:ok, rt} = QuickBEAM.start()

      for _ <- 1..3, do: QuickBEAM.reset(rt)
      :erlang.garbage_collect()
      Process.sleep(50)

      mem_before = :erlang.memory(:total)

      for _ <- 1..50 do
        QuickBEAM.eval(rt, "globalThis.x = 'some data'.repeat(100)")
        QuickBEAM.reset(rt)
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 1024 * 1024,
             "Memory grew by #{div(growth, 1024)}KB over 50 reset cycles"

      QuickBEAM.stop(rt)
    end

    test "runtime start/stop cycle does not leak" do
      for _ <- 1..5 do
        {:ok, rt} = QuickBEAM.start()
        QuickBEAM.eval(rt, "1 + 1")
        QuickBEAM.stop(rt)
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_before = :erlang.memory(:total)

      for _ <- 1..20 do
        {:ok, rt} = QuickBEAM.start()
        QuickBEAM.eval(rt, "globalThis.data = 'x'.repeat(10000)")
        QuickBEAM.stop(rt)
      end

      :erlang.garbage_collect()
      Process.sleep(100)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 2 * 1024 * 1024,
             "Memory grew by #{div(growth, 1024)}KB over 20 start/stop cycles"
    end
  end
end
