defmodule QuickBEAM.Core.ContextPoolStressTest do
  use ExUnit.Case

  @moduletag timeout: 120_000

  # ──────────────────── 1. Scale ────────────────────

  describe "mass context creation" do
    test "1000 contexts on a 4-thread pool" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      contexts =
        for i <- 1..1000 do
          {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
          {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{i}")
          ctx
        end

      # Spot-check 50 random contexts
      samples = Enum.take_random(Enum.with_index(contexts, 1), 50)

      for {ctx, i} <- samples do
        {:ok, val} = QuickBEAM.Context.eval(ctx, "id")
        assert val == i, "Context #{i} returned #{val}"
      end

      for ctx <- contexts, do: QuickBEAM.Context.stop(ctx)
    end

    test "rapid create/destroy churn — 500 cycles" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)

      for i <- 1..500 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
        {:ok, val} = QuickBEAM.Context.eval(ctx, "#{i} * 3")
        assert val == i * 3
        QuickBEAM.Context.stop(ctx)
      end

      # Pool still healthy after churn
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
      assert {:ok, 42} = QuickBEAM.Context.eval(ctx, "42")
      QuickBEAM.Context.stop(ctx)
    end

    test "destroy context while siblings are active on same thread" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)

      {:ok, ctx_a} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_b} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_c} = QuickBEAM.Context.start_link(pool: pool)

      {:ok, _} = QuickBEAM.Context.eval(ctx_a, "globalThis.x = 'a'")
      {:ok, _} = QuickBEAM.Context.eval(ctx_b, "globalThis.x = 'b'")
      {:ok, _} = QuickBEAM.Context.eval(ctx_c, "globalThis.x = 'c'")

      # Destroy B while A and C are still alive
      QuickBEAM.Context.stop(ctx_b)

      assert {:ok, "a"} = QuickBEAM.Context.eval(ctx_a, "x")
      assert {:ok, "c"} = QuickBEAM.Context.eval(ctx_c, "x")

      QuickBEAM.Context.stop(ctx_a)
      QuickBEAM.Context.stop(ctx_c)
    end
  end

  # ──────────────────── 2. Concurrency ────────────────────

  describe "thundering herd" do
    test "200 tasks hitting 50 contexts simultaneously" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      contexts =
        for i <- 1..50 do
          {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
          {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{i}")
          {i, ctx}
        end

      tasks =
        for _ <- 1..200 do
          {expected_id, ctx} = Enum.random(contexts)

          Task.async(fn ->
            {:ok, val} = QuickBEAM.Context.eval(ctx, "id")
            assert val == expected_id
            val
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 200
      assert Enum.all?(results, &is_integer/1)

      for {_, ctx} <- contexts, do: QuickBEAM.Context.stop(ctx)
    end

    test "Beam.call from 100 contexts simultaneously" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      contexts =
        for i <- 1..100 do
          {:ok, ctx} =
            QuickBEAM.Context.start_link(
              pool: pool,
              handlers: %{
                "slow_echo" => fn [val] ->
                  Process.sleep(10)
                  val
                end
              }
            )

          {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.myId = #{i}")
          {i, ctx}
        end

      tasks =
        for {i, ctx} <- contexts do
          Task.async(fn ->
            {:ok, result} = QuickBEAM.Context.eval(ctx, "await Beam.call('slow_echo', myId)")
            assert result == i
            result
          end)
        end

      results = Task.await_many(tasks, 60_000)
      assert Enum.sort(results) == Enum.to_list(1..100)

      for {_, ctx} <- contexts, do: QuickBEAM.Context.stop(ctx)
    end

    test "Beam.callSync from many contexts on same thread serializes correctly" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
      counter = :counters.new(1, [:atomics])

      contexts =
        for i <- 1..20 do
          {:ok, ctx} =
            QuickBEAM.Context.start_link(
              pool: pool,
              handlers: %{
                "count" => fn [val] ->
                  :counters.add(counter, 1, 1)
                  val * 2
                end
              }
            )

          {i, ctx}
        end

      # Sequential — each callSync blocks the single thread
      for {i, ctx} <- contexts do
        {:ok, result} = QuickBEAM.Context.eval(ctx, "Beam.callSync('count', #{i})")
        assert result == i * 2
      end

      assert :counters.get(counter, 1) == 20

      for {_, ctx} <- contexts, do: QuickBEAM.Context.stop(ctx)
    end
  end

  # ──────────────────── 3. Memory ────────────────────

  describe "memory stability" do
    test "context create/destroy cycle doesn't leak" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)

      # Warm up
      for _ <- 1..5 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

        QuickBEAM.Context.eval(ctx, """
        globalThis.data = [];
        for (let i = 0; i < 1000; i++) data.push({x: i, y: 'test'.repeat(10)});
        """)

        QuickBEAM.Context.stop(ctx)
      end

      :erlang.garbage_collect()
      Process.sleep(100)
      mem_before = :erlang.memory(:total)

      for _ <- 1..100 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

        QuickBEAM.Context.eval(ctx, """
        globalThis.data = [];
        for (let i = 0; i < 1000; i++) data.push({x: i, y: 'test'.repeat(10)});
        """)

        QuickBEAM.Context.stop(ctx)
      end

      :erlang.garbage_collect()
      Process.sleep(100)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 4 * 1024 * 1024,
             "BEAM memory grew by #{div(growth, 1024)}KB over 100 create/destroy cycles"
    end

    test "rolling context churn over 3 seconds" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)
      alive = :ets.new(:alive_contexts, [:set, :public])

      # Seed 50 contexts
      for i <- 1..50 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
        {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{i}")
        :ets.insert(alive, {i, ctx})
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_before = :erlang.memory(:total)

      # Churn for 3 seconds: destroy oldest, create new
      deadline = System.monotonic_time(:millisecond) + 3_000
      next_id = 51

      {_, next_id} =
        Enum.reduce_while(Stream.iterate(1, &(&1 + 1)), {1, next_id}, fn destroy_id, {_, nid} ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:halt, {destroy_id, nid}}
          else
            case :ets.lookup(alive, destroy_id) do
              [{^destroy_id, ctx}] ->
                QuickBEAM.Context.stop(ctx)
                :ets.delete(alive, destroy_id)

              [] ->
                :ok
            end

            {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
            {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{nid}")
            :ets.insert(alive, {nid, ctx})
            {:cont, {destroy_id + 1, nid + 1}}
          end
        end)

      :erlang.garbage_collect()
      Process.sleep(100)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before
      churn_count = next_id - 51

      assert growth < 8 * 1024 * 1024,
             "BEAM memory grew by #{div(growth, 1024)}KB over #{churn_count} churn cycles"

      # Clean up remaining
      :ets.foldl(fn {_, ctx}, _ -> QuickBEAM.Context.stop(ctx) end, nil, alive)
      :ets.delete(alive)
    end

    test "eval cycles on long-lived context don't leak" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

      for _ <- 1..10, do: QuickBEAM.Context.eval(ctx, "JSON.parse(JSON.stringify({a: 1}))")

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_before = :erlang.memory(:total)

      for _ <- 1..2000 do
        QuickBEAM.Context.eval(ctx, "JSON.parse(JSON.stringify({a: [1,2,3], b: 'hello'}))")
      end

      :erlang.garbage_collect()
      Process.sleep(50)
      mem_after = :erlang.memory(:total)

      growth = mem_after - mem_before

      assert growth < 2 * 1024 * 1024,
             "BEAM memory grew by #{div(growth, 1024)}KB over 2000 eval cycles"

      QuickBEAM.Context.stop(ctx)
    end
  end

  # ──────────────────── 4. State Isolation ────────────────────

  describe "state isolation" do
    test "100 contexts each with unique global, no cross-contamination" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      contexts =
        for i <- 1..100 do
          {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
          {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.x = #{i}")
          {i, ctx}
        end

      # Shuffle and verify — if isolation is broken, we'd see wrong values
      shuffled = Enum.shuffle(contexts)

      for {expected, ctx} <- shuffled do
        {:ok, val} = QuickBEAM.Context.eval(ctx, "x")
        assert val == expected, "Expected #{expected}, got #{val}"
      end

      for {_, ctx} <- contexts, do: QuickBEAM.Context.stop(ctx)
    end

    test "prototype modification in one context doesn't leak to another" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)

      {:ok, ctx_polluter} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_clean} = QuickBEAM.Context.start_link(pool: pool)

      # Pollute prototypes in one context
      {:ok, _} =
        QuickBEAM.Context.eval(ctx_polluter, """
        Array.prototype.customMethod = function() { return 'polluted'; };
        Object.prototype.leaked = true;
        String.prototype.evil = () => 'hacked';
        """)

      # Verify pollution worked locally
      {:ok, "polluted"} = QuickBEAM.Context.eval(ctx_polluter, "[].customMethod()")

      # Verify clean context is unaffected
      {:ok, "undefined"} =
        QuickBEAM.Context.eval(ctx_clean, "typeof [].customMethod")

      {:ok, "undefined"} =
        QuickBEAM.Context.eval(ctx_clean, "typeof ({}).leaked")

      {:ok, "undefined"} =
        QuickBEAM.Context.eval(ctx_clean, "typeof ''.evil")

      QuickBEAM.Context.stop(ctx_polluter)
      QuickBEAM.Context.stop(ctx_clean)
    end

    test "globalThis.constructor tampering is isolated" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)

      {:ok, ctx_a} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_b} = QuickBEAM.Context.start_link(pool: pool)

      {:ok, _} =
        QuickBEAM.Context.eval(ctx_a, """
        globalThis.Math = { PI: 999 };
        globalThis.parseInt = (x) => 'hijacked';
        """)

      {:ok, 999} = QuickBEAM.Context.eval(ctx_a, "Math.PI")

      # ctx_b should have original Math and parseInt
      {:ok, pi} = QuickBEAM.Context.eval(ctx_b, "Math.PI")
      assert_in_delta pi, 3.14159, 0.001

      {:ok, 42} = QuickBEAM.Context.eval(ctx_b, "parseInt('42')")

      QuickBEAM.Context.stop(ctx_a)
      QuickBEAM.Context.stop(ctx_b)
    end
  end

  # ──────────────────── 5. Error Recovery ────────────────────

  describe "error recovery" do
    test "errors in one context don't poison siblings" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)

      {:ok, ctx_bad} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_good} = QuickBEAM.Context.start_link(pool: pool)

      # Throw errors, stack overflow, syntax error
      {:error, _} = QuickBEAM.Context.eval(ctx_bad, "throw new Error('boom')")

      {:error, _} =
        QuickBEAM.Context.eval(ctx_bad, "function f() { f() }; f()")

      {:error, _} = QuickBEAM.Context.eval(ctx_bad, "this is not valid javascript !!!")

      # Good context is completely unaffected
      assert {:ok, 42} = QuickBEAM.Context.eval(ctx_good, "42")
      assert {:ok, "hello"} = QuickBEAM.Context.eval(ctx_good, "'hello'")

      # Bad context recovers too
      assert {:ok, 99} = QuickBEAM.Context.eval(ctx_bad, "99")

      QuickBEAM.Context.stop(ctx_bad)
      QuickBEAM.Context.stop(ctx_good)
    end

    test "100 sequential errors on one context don't corrupt pool" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)
      {:ok, ctx_err} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_ok} = QuickBEAM.Context.start_link(pool: pool)

      for i <- 1..100 do
        {:error, _} = QuickBEAM.Context.eval(ctx_err, "throw new Error('err #{i}')")
      end

      # Pool and sibling healthy
      assert {:ok, "alive"} = QuickBEAM.Context.eval(ctx_ok, "'alive'")
      assert {:ok, "recovered"} = QuickBEAM.Context.eval(ctx_err, "'recovered'")

      QuickBEAM.Context.stop(ctx_err)
      QuickBEAM.Context.stop(ctx_ok)
    end

    test "timeout on one context doesn't block others" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)

      {:ok, ctx_slow} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_fast} = QuickBEAM.Context.start_link(pool: pool)

      # Start infinite loop with timeout on ctx_slow
      task_slow =
        Task.async(fn ->
          QuickBEAM.Context.eval(ctx_slow, "while(true) {}", timeout: 200)
        end)

      # Wait for the slow one to finish (with timeout error)
      {:error, _} = Task.await(task_slow, 5_000)

      # Now ctx_fast should respond promptly
      start = System.monotonic_time(:millisecond)
      {:ok, 7} = QuickBEAM.Context.eval(ctx_fast, "3 + 4")
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 500, "Fast context took #{elapsed}ms, expected < 500ms"

      QuickBEAM.Context.stop(ctx_slow)
      QuickBEAM.Context.stop(ctx_fast)
    end

    test "OOM in one context doesn't crash the pool" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1, memory_limit: 4 * 1024 * 1024)

      {:ok, ctx_oom} = QuickBEAM.Context.start_link(pool: pool)
      {:ok, ctx_ok} = QuickBEAM.Context.start_link(pool: pool)

      {:error, _} =
        QuickBEAM.Context.eval(ctx_oom, """
        const arrays = [];
        while (true) arrays.push(new Array(10000).fill('x'));
        """)

      # Sibling and pool still work
      assert {:ok, "fine"} = QuickBEAM.Context.eval(ctx_ok, "'fine'")

      QuickBEAM.Context.stop(ctx_oom)
      QuickBEAM.Context.stop(ctx_ok)
    end
  end

  # ──────────────────── 6. Handler Contention ────────────────────

  describe "handler contention" do
    test "slow handler doesn't starve fast contexts on multi-thread pool" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      {:ok, ctx_slow} =
        QuickBEAM.Context.start_link(
          pool: pool,
          handlers: %{
            "block" => fn [] ->
              Process.sleep(500)
              "done"
            end
          }
        )

      fast_contexts =
        for i <- 1..10 do
          {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
          {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{i}")
          {i, ctx}
        end

      # Start the slow call
      slow_task =
        Task.async(fn ->
          QuickBEAM.Context.eval(ctx_slow, "await Beam.call('block')")
        end)

      Process.sleep(50)

      # Fast contexts should respond quickly (on other threads)
      fast_tasks =
        for {i, ctx} <- fast_contexts do
          Task.async(fn ->
            start = System.monotonic_time(:millisecond)
            {:ok, val} = QuickBEAM.Context.eval(ctx, "id")
            elapsed = System.monotonic_time(:millisecond) - start
            assert val == i
            elapsed
          end)
        end

      fast_times = Task.await_many(fast_tasks, 5_000)
      avg_fast = Enum.sum(fast_times) / length(fast_times)

      assert avg_fast < 200,
             "Average fast eval took #{avg_fast}ms during slow handler"

      {:ok, "done"} = Task.await(slow_task, 5_000)

      QuickBEAM.Context.stop(ctx_slow)
      for {_, ctx} <- fast_contexts, do: QuickBEAM.Context.stop(ctx)
    end

    test "handler error doesn't leak into other contexts' calls" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)

      {:ok, ctx_fail} =
        QuickBEAM.Context.start_link(
          pool: pool,
          handlers: %{"fail" => fn _ -> raise "handler exploded" end}
        )

      {:ok, ctx_ok} =
        QuickBEAM.Context.start_link(
          pool: pool,
          handlers: %{"echo" => fn [val] -> val end}
        )

      # Fire both in parallel
      task_fail =
        Task.async(fn ->
          QuickBEAM.Context.eval(ctx_fail, "await Beam.call('fail')")
        end)

      task_ok =
        Task.async(fn ->
          QuickBEAM.Context.eval(ctx_ok, "await Beam.call('echo', 42)")
        end)

      {:error, _} = Task.await(task_fail, 5_000)
      {:ok, 42} = Task.await(task_ok, 5_000)

      # Both contexts still usable
      assert {:ok, 1} = QuickBEAM.Context.eval(ctx_fail, "1")
      assert {:ok, 2} = QuickBEAM.Context.eval(ctx_ok, "2")

      QuickBEAM.Context.stop(ctx_fail)
      QuickBEAM.Context.stop(ctx_ok)
    end

    test "Beam.call with concurrent handlers across 50 contexts" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      contexts =
        for i <- 1..50 do
          {:ok, ctx} =
            QuickBEAM.Context.start_link(
              pool: pool,
              handlers: %{
                "compute" => fn [val] -> val * val end
              }
            )

          {i, ctx}
        end

      tasks =
        for {i, ctx} <- contexts do
          Task.async(fn ->
            {:ok, result} =
              QuickBEAM.Context.eval(ctx, "await Beam.call('compute', #{i})")

            assert result == i * i
            result
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.sort(results) == Enum.map(1..50, &(&1 * &1)) |> Enum.sort()

      for {_, ctx} <- contexts, do: QuickBEAM.Context.stop(ctx)
    end
  end

  # ──────────────────── 7. Messaging Under Load ────────────────────

  describe "messaging under load" do
    test "1000 messages spread across 50 contexts — no cross-delivery" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

      contexts =
        for i <- 1..50 do
          {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

          {:ok, _} =
            QuickBEAM.Context.eval(ctx, """
            globalThis.received = [];
            globalThis.myId = #{i};
            Beam.onMessage((msg) => {
              globalThis.received.push(msg);
            });
            """)

          {i, ctx}
        end

      # Send 20 messages to each context, each tagged with a unique value
      for {i, ctx} <- contexts do
        for j <- 1..20 do
          QuickBEAM.Context.send_message(ctx, i * 1000 + j)
        end
      end

      # Wait for delivery
      Process.sleep(500)

      # Verify each context received exactly its messages
      for {i, ctx} <- contexts do
        {:ok, received} = QuickBEAM.Context.eval(ctx, "globalThis.received")
        expected = for j <- 1..20, do: i * 1000 + j

        assert Enum.sort(received) == Enum.sort(expected),
               "Context #{i}: expected #{inspect(expected)}, got #{inspect(received)}"
      end

      for {_, ctx} <- contexts, do: QuickBEAM.Context.stop(ctx)
    end

    test "messages during Beam.call don't get dropped" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)

      {:ok, ctx} =
        QuickBEAM.Context.start_link(
          pool: pool,
          handlers: %{
            "slow" => fn [] ->
              Process.sleep(200)
              "done"
            end
          }
        )

      {:ok, _} =
        QuickBEAM.Context.eval(ctx, """
        globalThis.msgs = [];
        Beam.onMessage((m) => globalThis.msgs.push(m));
        """)

      # Start a slow Beam.call
      task =
        Task.async(fn ->
          QuickBEAM.Context.eval(ctx, "await Beam.call('slow')")
        end)

      # While it's running, send messages
      Process.sleep(50)
      for i <- 1..20, do: QuickBEAM.Context.send_message(ctx, i)

      {:ok, "done"} = Task.await(task, 10_000)

      # Wait for message delivery
      eventually(fn ->
        {:ok, msgs} = QuickBEAM.Context.eval(ctx, "globalThis.msgs")
        assert length(msgs) == 20
      end)

      QuickBEAM.Context.stop(ctx)
    end

    test "burst of 500 messages to a single context" do
      {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
      {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

      {:ok, _} =
        QuickBEAM.Context.eval(ctx, """
        globalThis.received = [];
        Beam.onMessage((msg) => globalThis.received.push(msg));
        """)

      for i <- 1..500, do: QuickBEAM.Context.send_message(ctx, i)

      eventually(fn ->
        {:ok, count} = QuickBEAM.Context.eval(ctx, "globalThis.received.length")
        assert count == 500
      end)

      {:ok, received} = QuickBEAM.Context.eval(ctx, "globalThis.received")
      assert Enum.sort(received) == Enum.to_list(1..500)

      QuickBEAM.Context.stop(ctx)
    end
  end

  # ──────────────────── Helpers ────────────────────

  defp eventually(fun, attempts \\ 40) do
    fun.()
  rescue
    e in [ExUnit.AssertionError] ->
      if attempts > 0 do
        Process.sleep(50)
        eventually(fun, attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  catch
    :exit, reason ->
      if attempts > 0 do
        Process.sleep(50)
        eventually(fun, attempts - 1)
      else
        exit(reason)
      end
  end
end
