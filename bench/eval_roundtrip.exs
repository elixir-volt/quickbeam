# Benchmark 1: Eval round-trip latency
#
# How fast is: Elixir → eval JS → result back to Elixir?
# Measures the bridge overhead, not JS computation.

{:ok, qb} = QuickBEAM.start()
{:ok, qjs} = QuickJSEx.start()

Benchee.run(
  %{
    "QuickBEAM" => fn -> {:ok, 3} = QuickBEAM.eval(qb, "1 + 2") end,
    "QuickJSEx" => fn -> {:ok, 3} = QuickJSEx.eval(qjs, "1 + 2") end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)

QuickBEAM.stop(qb)
QuickJSEx.stop(qjs)
