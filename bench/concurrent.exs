# Benchmark 5: Concurrent throughput
#
# N runtimes each doing work in parallel. Does QuickBEAM scale with
# BEAM schedulers? Each runtime is on its own dirty IO thread.

concurrency_levels = [1, 2, 4, 8, System.schedulers_online()]

js_code = """
function fib(n) {
  if (n <= 1) return n;
  return fib(n - 1) + fib(n - 2);
}
"""

for n <- concurrency_levels |> Enum.uniq() do
  qb_runtimes = for _ <- 1..n do
    {:ok, rt} = QuickBEAM.start()
    {:ok, _} = QuickBEAM.eval(rt, js_code)
    rt
  end

  qjs_runtimes = for _ <- 1..n do
    {:ok, rt} = QuickJSEx.start()
    {:ok, _} = QuickJSEx.eval(rt, js_code)
    rt
  end

  IO.puts("\n=== #{n} concurrent runtimes ===\n")

  Benchee.run(
    %{
      "QuickBEAM × #{n}" => fn ->
        qb_runtimes
        |> Enum.map(fn rt -> Task.async(fn -> {:ok, _} = QuickBEAM.call(rt, "fib", [25]) end) end)
        |> Task.await_many(10_000)
      end,
      "QuickJSEx × #{n}" => fn ->
        qjs_runtimes
        |> Enum.map(fn rt -> Task.async(fn -> {:ok, _} = QuickJSEx.call(rt, "fib", [25]) end) end)
        |> Task.await_many(10_000)
      end
    },
    warmup: 1,
    time: 5,
    memory_time: 0,
    print: [configuration: false]
  )

  for rt <- qb_runtimes, do: QuickBEAM.stop(rt)
  for rt <- qjs_runtimes, do: QuickJSEx.stop(rt)
end
