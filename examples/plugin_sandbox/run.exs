{:ok, _} = PluginSandbox.start_link()

# ── Plugin 1: Discount calculator with KV state ──

:ok = PluginSandbox.load_plugin(:pricing, """
  async function configure(rules) {
    for (const [tier, discount] of Object.entries(rules)) {
      await Beam.call("kv.set", tier, discount)
    }
  }

  async function calculate(tier, price) {
    const discount = await Beam.call("kv.get", tier) || 0
    return { original: price, discount, final: price * (1 - discount) }
  }
""", [:kv])

PluginSandbox.call_plugin(:pricing, "configure", [
  %{"bronze" => 0.05, "silver" => 0.10, "gold" => 0.20}
])

{:ok, result} = PluginSandbox.call_plugin(:pricing, "calculate", ["gold", 100])
IO.puts("Gold tier: $#{result["original"]} → $#{result["final"]} (#{trunc(result["discount"] * 100)}% off)")

# ── Plugin 2: Text transform (no capabilities — fully sandboxed) ──

:ok = PluginSandbox.load_plugin(:transform, """
  function process(text) {
    return {
      upper: text.toUpperCase(),
      words: text.split(/\\s+/).length,
      reversed: text.split("").reverse().join("")
    }
  }
""")

{:ok, result} = PluginSandbox.call_plugin(:transform, "process", ["Hello QuickBEAM"])
IO.puts("Transform: #{inspect(result)}")

# ── Plugin 3: Memory hog — gets killed ──

IO.puts("\nLoading memory hog plugin (2 MB limit)...")

:ok = PluginSandbox.load_plugin(:hog, """
  function hog() {
    const arr = []
    while (true) arr.push("x".repeat(1024))
  }
""", [], memory_limit: 2 * 1024 * 1024)

case PluginSandbox.call_plugin(:hog, "hog") do
  {:error, error} -> IO.puts("Memory hog stopped: #{inspect(error)}")
  other -> IO.puts("Unexpected: #{inspect(other)}")
end

# ── Plugin 4: Infinite loop — gets timed out ──

IO.puts("\nLoading infinite loop plugin (1s timeout)...")

:ok = PluginSandbox.load_plugin(:looper, """
  function loop() { while (true) {} }
""")

case PluginSandbox.call_plugin(:looper, "loop", [], timeout: 1_000) do
  {:error, error} -> IO.puts("Infinite loop stopped: #{error.message}")
  other -> IO.puts("Unexpected: #{inspect(other)}")
end

IO.puts("\nLoaded plugins: #{inspect(PluginSandbox.list_plugins())}")
