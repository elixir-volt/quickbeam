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

  test "DOM operations on context" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    {:ok, _} =
      QuickBEAM.Context.eval(ctx, """
      document.body.innerHTML = '<div class="app"><h1>Title</h1><p>Content</p></div>'
      """)

    assert {:ok, {"h1", [], ["Title"]}} = QuickBEAM.Context.dom_find(ctx, "h1")
    assert {:ok, "Title"} = QuickBEAM.Context.dom_text(ctx, "h1")
    {:ok, html} = QuickBEAM.Context.dom_html(ctx)
    assert html =~ "<h1>Title</h1>"

    {:ok, items} = QuickBEAM.Context.dom_find_all(ctx, "div.app > *")
    assert length(items) == 2

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

  test "Worker on context pool sends message back to parent" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    assert {:ok, "hello from worker"} =
             QuickBEAM.Context.eval(ctx, """
             await new Promise((resolve) => {
               const w = new Worker(`self.postMessage("hello from worker")`);
               w.onmessage = (e) => resolve(e.data);
             })
             """)

    QuickBEAM.Context.stop(ctx)
  end

  test "Worker on context pool receives message from parent" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    assert {:ok, "pong: ping"} =
             QuickBEAM.Context.eval(ctx, """
             await new Promise((resolve) => {
               const w = new Worker(`
                 self.onmessage = (e) => {
                   self.postMessage("pong: " + e.data);
                 };
               `);
               setTimeout(() => {
                 w.onmessage = (e) => resolve(e.data);
                 w.postMessage("ping");
               }, 50);
             })
             """)

    QuickBEAM.Context.stop(ctx)
  end

  test "multiple Workers on context pool run concurrently" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 4)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    assert {:ok, [1, 2, 3]} =
             QuickBEAM.Context.eval(
               ctx,
               """
               await new Promise((resolve) => {
                 const results = [];
                 let count = 0;
                 for (let i = 1; i <= 3; i++) {
                   const w = new Worker(`self.postMessage(${i})`);
                   w.onmessage = (e) => {
                     results.push(e.data);
                     count++;
                     if (count === 3) resolve(results.sort());
                   };
                 }
               })
               """,
               timeout: 10_000
             )

    QuickBEAM.Context.stop(ctx)
  end

  test "Worker can be terminated on context pool" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 2)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    assert {:ok, "terminated"} =
             QuickBEAM.Context.eval(ctx, """
             const w = new Worker(`
               setTimeout(() => self.postMessage("should not arrive"), 500);
             `);
             w.terminate();
             "terminated"
             """)

    QuickBEAM.Context.stop(ctx)
  end

  test "get_global and set_global on context" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link(size: 1)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool)

    :ok = QuickBEAM.Context.set_global(ctx, "myVal", 42)
    assert {:ok, 42} = QuickBEAM.Context.get_global(ctx, "myVal")

    :ok = QuickBEAM.Context.set_global(ctx, "myObj", %{"a" => 1})
    assert {:ok, %{"a" => 1}} = QuickBEAM.Context.get_global(ctx, "myObj")

    QuickBEAM.Context.stop(ctx)
  end

  test "memory_limit rejects large allocations" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool, apis: false, memory_limit: 200_000)

    assert {:error, _} =
             QuickBEAM.Context.eval(ctx, "new Array(100000).fill('hello world')")

    QuickBEAM.Context.stop(ctx)
  end

  test "max_reductions interrupts long loops" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()

    {:ok, ctx} =
      QuickBEAM.Context.start_link(pool: pool, apis: false, max_reductions: 100_000)

    assert {:error, %QuickBEAM.JSError{message: "reduction limit exceeded"}} =
             QuickBEAM.Context.eval(
               ctx,
               "(() => { let s = 0; for(let i = 0; i < 10000000; i++) s += i; return s })()"
             )

    QuickBEAM.Context.stop(ctx)
  end

  test "context recovers after hitting reduction limit" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()

    {:ok, ctx} =
      QuickBEAM.Context.start_link(pool: pool, apis: false, max_reductions: 100_000)

    assert {:error, _} =
             QuickBEAM.Context.eval(
               ctx,
               "(() => { let s = 0; for(let i = 0; i < 10000000; i++) s += i; return s })()"
             )

    assert {:ok, 42} = QuickBEAM.Context.eval(ctx, "42")

    QuickBEAM.Context.stop(ctx)
  end

  test "memory_usage includes context_malloc_size" do
    {:ok, pool} = QuickBEAM.ContextPool.start_link()
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: pool, apis: false)

    {:ok, mem} = QuickBEAM.Context.memory_usage(ctx)
    assert is_integer(mem.context_malloc_size)
    assert mem.context_malloc_size > 0

    QuickBEAM.Context.stop(ctx)
  end
end
