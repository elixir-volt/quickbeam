# Benchmark 4: Runtime startup cost
#
# How fast can we spin up a new JS runtime?
# Matters for per-request or per-tenant isolation patterns.

Benchee.run(
  %{
    "QuickBEAM start+stop" => fn ->
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.stop(rt)
    end,
    "QuickJSEx start+stop" => fn ->
      {:ok, rt} = QuickJSEx.start()
      QuickJSEx.stop(rt)
    end,
    "QuickBEAM start+eval+stop" => fn ->
      {:ok, rt} = QuickBEAM.start()
      {:ok, 3} = QuickBEAM.eval(rt, "1 + 2")
      QuickBEAM.stop(rt)
    end,
    "QuickJSEx start+eval+stop" => fn ->
      {:ok, rt} = QuickJSEx.start()
      {:ok, 3} = QuickJSEx.eval(rt, "1 + 2")
      QuickJSEx.stop(rt)
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  print: [configuration: false]
)
