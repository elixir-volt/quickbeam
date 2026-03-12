js_dir = Path.join(__DIR__, "priv/js") |> Path.expand()
{:ok, sup} = LiveDashboard.start_link(js_dir: js_dir)

Process.sleep(300)

header = """
╔══════════════════════════════════════════════════════╗
║         QuickBEAM Live Dashboard Example             ║
║  Workers = BEAM processes  ·  BroadcastChannel = :pg ║
╚══════════════════════════════════════════════════════╝
"""

IO.puts(header)

for i <- 1..5 do
  LiveDashboard.collect()
  Process.sleep(400)

  {:ok, dashboard} = LiveDashboard.get_dashboard()

  IO.puts("── Snapshot #{i} ─────────────────────────────────────")

  if dashboard["cpu"] do
    cpu = dashboard["cpu"]
    IO.puts("  CPU    #{cpu["usage"]}%  load: #{inspect(cpu["load_avg"])}  cores: #{cpu["cores"]}")
  end

  if dashboard["memory"] do
    mem = dashboard["memory"]
    bar_len = round(mem["usage_percent"] / 5)
    bar = String.duplicate("█", bar_len) <> String.duplicate("░", 20 - bar_len)
    IO.puts("  MEM    [#{bar}] #{mem["usage_percent"]}%  (#{mem["used_mb"]}/#{mem["total_mb"]} MB)")
  end

  if dashboard["requests"] do
    req = dashboard["requests"]
    IO.puts("  REQ    #{req["rps"]} rps  latency: #{req["avg_latency_ms"]}ms  errors: #{req["error_rate"]}%  conns: #{req["active_connections"]}")
  end

  IO.puts("  updated: #{dashboard["last_updated"]}")
  IO.puts("")
end

IO.puts("── Crash Recovery ──────────────────────────────────")
old_pid = Process.whereis(:coordinator)
IO.puts("  Killing coordinator (pid: #{inspect(old_pid)})...")
Process.exit(old_pid, :kill)
Process.sleep(500)

new_pid = Process.whereis(:coordinator)
IO.puts("  Supervisor restarted it (pid: #{inspect(new_pid)})")

Process.sleep(300)

LiveDashboard.collect()
Process.sleep(400)

{:ok, dashboard} = LiveDashboard.get_dashboard()
IO.puts("  Post-recovery collection: #{dashboard["collection_count"]} collections")

if dashboard["cpu"] do
  IO.puts("  CPU: #{dashboard["cpu"]["usage"]}%  ✓ Workers re-created")
end

IO.puts("")
IO.puts("Done.")

Supervisor.stop(sup)
