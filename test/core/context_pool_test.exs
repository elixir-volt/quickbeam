defmodule QuickBEAM.Core.ContextPoolTest do
  use ExUnit.Case, async: true

  test "create pool and context, eval simple expression" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    assert {:ok, 3} = QuickBEAM.Context.eval(ctx, "1 + 2")

    QuickBEAM.Context.stop(ctx)
  end

  test "context state persists across evals" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.x = 42")
    assert {:ok, 42} = QuickBEAM.Context.eval(ctx, "x")

    QuickBEAM.Context.stop(ctx)
  end

  test "multiple contexts are isolated" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx1} = QuickBEAM.Context.start_link(pool: pool)
    {:ok, ctx2} = QuickBEAM.Context.start_link(pool: pool)

    {:ok, _} = QuickBEAM.Context.eval(ctx1, "globalThis.x = 'from_ctx1'")

    assert {:ok, "from_ctx1"} = QuickBEAM.Context.eval(ctx1, "x")
    assert {:ok, "undefined"} = QuickBEAM.Context.eval(ctx2, "typeof x")

    QuickBEAM.Context.stop(ctx1)
    QuickBEAM.Context.stop(ctx2)
  end

  test "call JS function" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    {:ok, _} = QuickBEAM.Context.eval(ctx, "function add(a, b) { return a + b }")
    assert {:ok, 5} = QuickBEAM.Context.call(ctx, "add", [2, 3])

    QuickBEAM.Context.stop(ctx)
  end

  test "reset clears context state" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.x = 42")
    :ok = QuickBEAM.Context.reset(ctx)
    assert {:ok, "undefined"} = QuickBEAM.Context.eval(ctx, "typeof x")

    QuickBEAM.Context.stop(ctx)
  end

  test "Beam.call handler" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()

    {:ok, ctx} =
      QuickBEAM.Context.start_link(
        pool: pool,
        handlers: %{
          "greet" => fn [name] -> "Hello, #{name}!" end
        }
      )

    assert {:ok, "Hello, world!"} =
             QuickBEAM.Context.eval(ctx, ~s[await Beam.call("greet", "world")])

    QuickBEAM.Context.stop(ctx)
  end

  test "many contexts on one pool" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()

    contexts =
      for i <- 1..50 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
        {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{i}")
        ctx
      end

    results =
      for ctx <- contexts do
        {:ok, val} = QuickBEAM.Context.eval(ctx, "id")
        val
      end

    assert results == Enum.to_list(1..50)

    for ctx <- contexts, do: QuickBEAM.Context.stop(ctx)
  end

  test "concurrent eval on different contexts" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()

    contexts =
      for i <- 1..10 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
        {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.val = #{i}")
        ctx
      end

    tasks =
      for {ctx, i} <- Enum.with_index(contexts, 1) do
        Task.async(fn ->
          {:ok, result} = QuickBEAM.Context.eval(ctx, "val * 2")
          assert result == i * 2
          result
        end)
      end

    results = Task.await_many(tasks)
    assert results == Enum.map(1..10, &(&1 * 2))

    for ctx <- contexts, do: QuickBEAM.Context.stop(ctx)
  end

  test "context cleanup on stop" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
    {:ok, 42} = QuickBEAM.Context.eval(ctx, "42")
    QuickBEAM.Context.stop(ctx)

    # Pool still works after context is destroyed
    {:ok, ctx2} = QuickBEAM.Context.start_link(pool: pool)
    assert {:ok, 7} = QuickBEAM.Context.eval(ctx2, "3 + 4")
    QuickBEAM.Context.stop(ctx2)
  end

  test "multi-thread pool distributes contexts across threads" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)

    # Create contexts that will be distributed across 4 threads
    contexts =
      for i <- 1..20 do
        {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)
        {:ok, _} = QuickBEAM.Context.eval(ctx, "globalThis.id = #{i}")
        ctx
      end

    # All contexts work independently
    tasks =
      for {ctx, i} <- Enum.with_index(contexts, 1) do
        Task.async(fn ->
          {:ok, val} = QuickBEAM.Context.eval(ctx, "id")
          assert val == i
          val
        end)
      end

    results = Task.await_many(tasks)
    assert results == Enum.to_list(1..20)

    for ctx <- contexts, do: QuickBEAM.Context.stop(ctx)
  end

  test "browser APIs available in context" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    # URL parsing (browser API backed by Beam handler)
    assert {:ok, "example.com"} =
             QuickBEAM.Context.eval(ctx, "new URL('https://example.com/path').hostname")

    # crypto.getRandomValues (native Zig)
    assert {:ok, 16} =
             QuickBEAM.Context.eval(ctx, "crypto.getRandomValues(new Uint8Array(16)).length")

    # performance.now (native Zig)
    {:ok, ms} = QuickBEAM.Context.eval(ctx, "performance.now()")
    assert is_float(ms) and ms >= 0

    # console (logs to Logger)
    assert {:ok, nil} = QuickBEAM.Context.eval(ctx, "console.log('from context')")

    # setTimeout
    assert {:ok, "done"} =
             QuickBEAM.Context.eval(ctx, """
             await new Promise(resolve => setTimeout(() => resolve('done'), 10))
             """)

    QuickBEAM.Context.stop(ctx)
  end

  test "send_message to context" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    {:ok, _} =
      QuickBEAM.Context.eval(ctx, """
      globalThis.lastMsg = null;
      Beam.onMessage((msg) => { globalThis.lastMsg = msg; });
      """)

    QuickBEAM.Context.send_message(ctx, "hello")
    Process.sleep(50)

    assert {:ok, "hello"} = QuickBEAM.Context.eval(ctx, "lastMsg")

    QuickBEAM.Context.stop(ctx)
  end
end
