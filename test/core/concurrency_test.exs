defmodule QuickBEAM.Core.ConcurrencyTest do
  use ExUnit.Case

  @moduletag timeout: 30_000

  describe "concurrent eval on same runtime" do
    test "parallel evals serialize correctly" do
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "globalThis.counter = 0")

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            {:ok, _} = QuickBEAM.eval(rt, "globalThis.counter += #{i}")
          end)
        end

      Task.await_many(tasks, 10_000)

      {:ok, final} = QuickBEAM.eval(rt, "globalThis.counter")
      assert final == Enum.sum(1..50)
      QuickBEAM.stop(rt)
    end

    test "parallel eval and call interleaved" do
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "function mul(a, b) { return a * b }")

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            {:ok, result} = QuickBEAM.call(rt, "mul", [i, 2])
            assert result == i * 2
          end)
        end

      Task.await_many(tasks, 10_000)
      QuickBEAM.stop(rt)
    end

    test "eval interleaved with setTimeout callbacks" do
      {:ok, rt} = QuickBEAM.start()

      {:ok, result} =
        QuickBEAM.eval(rt, """
          await new Promise((resolve) => {
            let ticks = 0;
            for (let i = 0; i < 5; i++) {
              setTimeout(() => {
                ticks++;
                if (ticks === 5) resolve(ticks);
              }, i * 20);
            }
          })
        """)

      assert result == 5

      QuickBEAM.stop(rt)
    end
  end

  describe "concurrent Beam.call" do
    test "sequential async calls from different callers" do
      {:ok, rt} =
        QuickBEAM.start(handlers: %{"echo" => fn [val] -> val end})

      for i <- 1..10 do
        {:ok, result} = QuickBEAM.eval(rt, "await Beam.call('echo', #{i})")
        assert result == i
      end

      QuickBEAM.stop(rt)
    end

    test "callSync under contention" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "get_time" => fn [] -> System.monotonic_time(:microsecond) end
          }
        )

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            {:ok, t} = QuickBEAM.eval(rt, "Beam.callSync('get_time')")
            assert is_integer(t)
          end)
        end

      Task.await_many(tasks, 10_000)
      QuickBEAM.stop(rt)
    end

    test "handler that raises doesn't poison the runtime" do
      call_count = :counters.new(1, [:atomics])

      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "maybe_fail" => fn [n] ->
              :counters.add(call_count, 1, 1)
              if rem(n, 3) == 0, do: raise("boom"), else: n * 2
            end
          }
        )

      for i <- 1..30 do
        result = QuickBEAM.eval(rt, "await Beam.call('maybe_fail', #{i})")

        if rem(i, 3) == 0 do
          assert {:error, %QuickBEAM.JSError{}} = result
        else
          assert {:ok, val} = result
          assert val == i * 2
        end
      end

      assert :counters.get(call_count, 1) == 30
      QuickBEAM.stop(rt)
    end
  end

  describe "many runtimes in parallel" do
    test "start, eval, stop 20 runtimes concurrently" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            {:ok, rt} = QuickBEAM.start()
            {:ok, result} = QuickBEAM.eval(rt, "#{i} * #{i}")
            QuickBEAM.stop(rt)
            result
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert results == Enum.map(1..20, &(&1 * &1))
    end

    test "10 runtimes cross-communicate via BEAM" do
      test_pid = self()

      runtimes =
        for i <- 1..10 do
          {:ok, rt} =
            QuickBEAM.start(
              handlers: %{
                "report" => fn [id, val] ->
                  send(test_pid, {:report, id, val})
                  :ok
                end
              }
            )

          QuickBEAM.eval(rt, """
            Beam.onMessage(async (msg) => {
              await Beam.call("report", #{i}, msg * #{i});
            });
          """)

          rt
        end

      for rt <- runtimes, do: QuickBEAM.send_message(rt, 7)

      for i <- 1..10 do
        assert_receive {:report, ^i, val}, 2000
        assert val == 7 * i
      end

      for rt <- runtimes, do: QuickBEAM.stop(rt)
    end

    test "concurrent runtime init doesn't crash (class ID contention)" do
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            {:ok, rt} = QuickBEAM.start()

            {:ok, true} =
              QuickBEAM.eval(rt, """
                typeof document !== 'undefined' &&
                typeof fetch === 'function' &&
                typeof URL === 'function'
              """)

            QuickBEAM.stop(rt)
          end)
        end

      Task.await_many(tasks, 15_000)
    end
  end

  describe "messaging under load" do
    test "burst of 200 messages don't get lost" do
      {:ok, rt} = QuickBEAM.start()

      QuickBEAM.eval(rt, """
        globalThis.received = [];
        Beam.onMessage((msg) => {
          globalThis.received.push(msg);
        });
      """)

      for i <- 1..200, do: QuickBEAM.send_message(rt, i)

      eventually(fn ->
        {:ok, count} = QuickBEAM.eval(rt, "globalThis.received.length")
        assert count == 200
      end)

      {:ok, received} = QuickBEAM.eval(rt, "globalThis.received")
      assert Enum.sort(received) == Enum.to_list(1..200)
      QuickBEAM.stop(rt)
    end

    test "messages during Beam.call don't get dropped" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "slow" => fn [] ->
              Process.sleep(100)
              "done"
            end
          }
        )

      QuickBEAM.eval(rt, """
        globalThis.msgs = [];
        Beam.onMessage((m) => globalThis.msgs.push(m));
      """)

      task =
        Task.async(fn ->
          QuickBEAM.eval(rt, "await Beam.call('slow')")
        end)

      Process.sleep(20)

      for i <- 1..10, do: QuickBEAM.send_message(rt, i)

      {:ok, "done"} = Task.await(task, 5000)

      eventually(fn ->
        {:ok, msgs} = QuickBEAM.eval(rt, "globalThis.msgs")
        assert length(msgs) == 10
      end)

      QuickBEAM.stop(rt)
    end

    test "send_message to dead runtime doesn't crash caller" do
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.stop(rt)
      Process.sleep(10)
      QuickBEAM.send_message(rt, "should not crash")
    end
  end

  describe "shutdown safety" do
    test "stop while callSync handler is running" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "block" => fn [] ->
              Process.sleep(500)
              "late"
            end
          }
        )

      caller = spawn(fn -> QuickBEAM.eval(rt, "Beam.callSync('block')") end)
      ref = Process.monitor(caller)

      Process.sleep(50)

      try do
        GenServer.stop(rt, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      assert_receive {:DOWN, ^ref, :process, _, _}, 5000
    end

    test "rapid start/stop cycles" do
      for _ <- 1..30 do
        {:ok, rt} = QuickBEAM.start()
        QuickBEAM.eval(rt, "1 + 1")
        QuickBEAM.stop(rt)
      end
    end

    test "stop is idempotent (already dead)" do
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.stop(rt)

      assert catch_exit(QuickBEAM.stop(rt))
    end
  end

  describe "worker concurrency" do
    test "5 workers from same parent" do
      {:ok, rt} = QuickBEAM.start()

      {:ok, results} =
        QuickBEAM.eval(
          rt,
          """
          await Promise.all(
            Array.from({length: 5}, (_, i) =>
              new Promise((resolve) => {
                const w = new Worker(`self.postMessage(${i} * ${i})`);
                w.onmessage = (e) => resolve(e.data);
              })
            )
          )
          """,
          timeout: 10_000
        )

      assert Enum.sort(results) == [0, 1, 4, 9, 16]
      QuickBEAM.stop(rt)
    end

    test "worker with bidirectional messaging" do
      {:ok, rt} = QuickBEAM.start()

      {:ok, result} =
        QuickBEAM.eval(
          rt,
          """
          await new Promise((resolve) => {
            const w = new Worker(`
              self.onmessage = (e) => {
                self.postMessage(e.data.map(x => x * 2));
              };
            `);
            setTimeout(() => {
              w.onmessage = (e) => resolve(e.data);
              w.postMessage([1, 2, 3, 4, 5]);
            }, 50);
          })
          """,
          timeout: 5000
        )

      assert result == [2, 4, 6, 8, 10]
      QuickBEAM.stop(rt)
    end
  end

  describe "pool under contention" do
    test "pool handles 50 concurrent checkouts with size 3" do
      {:ok, pool} =
        QuickBEAM.Pool.start_link(
          size: 3,
          init: fn rt -> QuickBEAM.eval(rt, "function sq(x) { return x * x }") end
        )

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            QuickBEAM.Pool.run(pool, fn rt ->
              {:ok, result} = QuickBEAM.call(rt, "sq", [i])
              assert result == i * i
              result
            end)
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert Enum.sort(results) == Enum.map(1..50, &(&1 * &1)) |> Enum.sort()
    end

    test "pool with Beam.call handlers under load" do
      {:ok, pool} =
        QuickBEAM.Pool.start_link(
          size: 4,
          handlers: %{"echo" => fn [val] -> val end}
        )

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            QuickBEAM.Pool.run(pool, fn rt ->
              {:ok, result} = QuickBEAM.eval(rt, "await Beam.call('echo', #{i})")
              assert result == i
              result
            end)
          end)
        end

      results = Task.await_many(tasks, 15_000)
      assert Enum.sort(results) == Enum.to_list(1..20)
    end
  end

  describe "supervision under crash" do
    test "supervised runtime recovers after repeated kills" do
      Process.flag(:trap_exit, true)

      {:ok, sup} =
        Supervisor.start_link(
          [{QuickBEAM, name: :crash_test_c, handlers: %{"ping" => fn [] -> "pong" end}}],
          strategy: :one_for_one,
          max_restarts: 10,
          max_seconds: 5
        )

      for _ <- 1..5 do
        pid = Process.whereis(:crash_test_c)
        assert is_pid(pid)

        {:ok, "pong"} = QuickBEAM.eval(:crash_test_c, "await Beam.call('ping')")

        Process.exit(pid, :kill)

        eventually(fn ->
          new_pid = Process.whereis(:crash_test_c)
          assert is_pid(new_pid) and new_pid != pid
        end)
      end

      {:ok, "pong"} = QuickBEAM.eval(:crash_test_c, "await Beam.call('ping')")
      Supervisor.stop(sup)
    end

    test "one crash doesn't affect sibling runtime" do
      Process.flag(:trap_exit, true)

      {:ok, sup} =
        Supervisor.start_link(
          [
            {QuickBEAM, name: :stable_c, id: :stable_c},
            {QuickBEAM, name: :crashy_c, id: :crashy_c}
          ],
          strategy: :one_for_one
        )

      QuickBEAM.eval(:stable_c, "globalThis.state = 'preserved'")
      QuickBEAM.eval(:crashy_c, "globalThis.state = 'will_die'")

      Process.exit(Process.whereis(:crashy_c), :kill)

      eventually(fn ->
        assert Process.whereis(:crashy_c) != nil
      end)

      {:ok, "preserved"} = QuickBEAM.eval(:stable_c, "globalThis.state")
      {:ok, "undefined"} = QuickBEAM.eval(:crashy_c, "typeof globalThis.state")

      Supervisor.stop(sup)
    end
  end

  describe "BroadcastChannel cross-runtime" do
    setup do
      unless Process.whereis(QuickBEAM.BroadcastChannel),
        do: :pg.start_link(QuickBEAM.BroadcastChannel)

      :ok
    end

    test "message broadcast between 3 runtimes" do
      channel = "test_bc_#{System.unique_integer([:positive])}"

      runtimes =
        for i <- 1..3 do
          {:ok, rt} = QuickBEAM.start()

          QuickBEAM.eval(rt, """
            globalThis.received = [];
            globalThis.ch = new BroadcastChannel("#{channel}");
            globalThis.ch.onmessage = (e) => globalThis.received.push(e.data);
          """)

          {i, rt}
        end

      Process.sleep(100)

      for {i, rt} <- runtimes do
        QuickBEAM.eval(rt, "globalThis.ch.postMessage(#{i})")
      end

      eventually(fn ->
        for {i, rt} <- runtimes do
          {:ok, received} = QuickBEAM.eval(rt, "globalThis.received")
          others = Enum.map(runtimes, &elem(&1, 0)) -- [i]
          for other <- others, do: assert(other in received, "rt #{i} missing msg from #{other}")
        end
      end)

      for {_, rt} <- runtimes, do: QuickBEAM.stop(rt)
    end
  end

  describe "reset under concurrent access" do
    test "reset clears state and subsequent eval works" do
      {:ok, rt} = QuickBEAM.start()

      QuickBEAM.eval(rt, "globalThis.x = 'before'")
      {:ok, "before"} = QuickBEAM.eval(rt, "globalThis.x")

      :ok = QuickBEAM.reset(rt)

      {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof globalThis.x")
      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "many resets with eval between each" do
      {:ok, rt} = QuickBEAM.start()

      for i <- 1..20 do
        QuickBEAM.eval(rt, "globalThis.x = #{i}")
        {:ok, ^i} = QuickBEAM.eval(rt, "globalThis.x")
        :ok = QuickBEAM.reset(rt)
        {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof globalThis.x")
      end

      QuickBEAM.stop(rt)
    end
  end

  describe "data integrity under load" do
    test "large objects survive round-trip under concurrent eval" do
      {:ok, rt} = QuickBEAM.start()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {:ok, result} =
              QuickBEAM.eval(rt, """
                (function() {
                  var obj = {};
                  for (var j = 0; j < 100; j++) {
                    obj['key_' + j] = #{i} * 1000 + j;
                  }
                  return obj;
                })()
              """)

            assert map_size(result) == 100

            for j <- 0..99 do
              assert result["key_#{j}"] == i * 1000 + j
            end
          end)
        end

      Task.await_many(tasks, 10_000)
      QuickBEAM.stop(rt)
    end

    test "binary data (Uint8Array) round-trips correctly under load" do
      {:ok, rt} = QuickBEAM.start()

      for _ <- 1..50 do
        {:ok, result} =
          QuickBEAM.eval(rt, """
            (function() {
              var arr = new Uint8Array(256);
              for (var i = 0; i < 256; i++) arr[i] = i;
              return arr;
            })()
          """)

        assert byte_size(result) == 256
        assert result == :binary.list_to_bin(Enum.to_list(0..255))
      end

      QuickBEAM.stop(rt)
    end

    test "string encoding round-trip with unicode" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "echo" => fn [val] -> val end
          }
        )

      strings = [
        "Hello, World!",
        "こんにちは",
        "🎉🚀💻",
        "Ελληνικά",
        String.duplicate("a", 10_000),
        "mixed 日本語 with emoji 🎯 and ASCII"
      ]

      for s <- strings do
        {:ok, result} = QuickBEAM.eval(rt, "Beam.callSync('echo', #{Jason.encode!(s)})")
        assert result == s
      end

      QuickBEAM.stop(rt)
    end
  end

  describe "timeout behavior" do
    test "eval with timeout returns error on infinite loop" do
      {:ok, rt} = QuickBEAM.start()
      result = QuickBEAM.eval(rt, "while(true) {}", timeout: 200)
      assert {:error, %QuickBEAM.JSError{}} = result

      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "call with timeout returns error on slow function" do
      {:ok, rt} = QuickBEAM.start()

      QuickBEAM.eval(rt, """
        function slow() { const start = Date.now(); while(Date.now() - start < 5000) {} }
      """)

      result = QuickBEAM.call(rt, "slow", [], timeout: 200)
      assert {:error, %QuickBEAM.JSError{}} = result

      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "timeout doesn't corrupt runtime state" do
      {:ok, rt} = QuickBEAM.start()

      QuickBEAM.eval(rt, "globalThis.x = 1")

      {:error, _} = QuickBEAM.eval(rt, "globalThis.x = 2; while(true) {}", timeout: 100)

      {:ok, x} = QuickBEAM.eval(rt, "globalThis.x")
      assert x in [1, 2]

      QuickBEAM.eval(rt, "globalThis.y = 99")
      {:ok, 99} = QuickBEAM.eval(rt, "globalThis.y")

      QuickBEAM.stop(rt)
    end
  end

  describe "error recovery" do
    test "unhandled promise rejection doesn't crash runtime" do
      {:ok, rt} = QuickBEAM.start()

      QuickBEAM.eval(rt, "Promise.reject(new Error('ignored'))")
      Process.sleep(50)

      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "stack overflow doesn't crash runtime" do
      {:ok, rt} = QuickBEAM.start()

      {:error, %QuickBEAM.JSError{name: "RangeError"}} =
        QuickBEAM.eval(rt, "function f() { f() }; f()")

      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "OOM doesn't crash runtime" do
      {:ok, rt} = QuickBEAM.start(memory_limit: 2 * 1024 * 1024)

      {:error, _} =
        QuickBEAM.eval(rt, """
          const arrays = [];
          while(true) arrays.push(new Array(10000).fill('x'));
        """)

      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end

    test "100 sequential errors don't leak or crash" do
      {:ok, rt} = QuickBEAM.start()

      for _ <- 1..100 do
        {:error, _} = QuickBEAM.eval(rt, "throw new Error('boom')")
      end

      {:ok, 42} = QuickBEAM.eval(rt, "42")
      QuickBEAM.stop(rt)
    end
  end

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
