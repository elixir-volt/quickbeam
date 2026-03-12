defmodule LiveDashboardTest do
  use ExUnit.Case

  @js_dir Path.join(File.cwd!(), "priv/js")

  setup do
    start_supervised!({LiveDashboard, js_dir: @js_dir})
    Process.sleep(300)
    :ok
  end

  test "coordinator spawns 3 workers" do
    {:ok, count} = LiveDashboard.worker_count()
    assert count == 3
  end

  test "collect triggers metric generation" do
    LiveDashboard.collect()
    Process.sleep(500)

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    assert dashboard["collection_count"] == 1
  end

  test "workers produce CPU metrics via BroadcastChannel" do
    LiveDashboard.collect()
    Process.sleep(500)

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    cpu = dashboard["cpu"]
    assert is_number(cpu["usage"])
    assert cpu["usage"] >= 0 and cpu["usage"] <= 100
    assert cpu["cores"] == 8
    assert length(cpu["load_avg"]) == 3
  end

  test "workers produce memory metrics via BroadcastChannel" do
    LiveDashboard.collect()
    Process.sleep(500)

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    mem = dashboard["memory"]
    assert mem["total_mb"] == 16384
    assert is_number(mem["used_mb"])
    assert mem["free_mb"] == mem["total_mb"] - mem["used_mb"]
    assert is_number(mem["usage_percent"])
  end

  test "workers produce request metrics via BroadcastChannel" do
    LiveDashboard.collect()
    Process.sleep(500)

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    req = dashboard["requests"]
    assert is_number(req["rps"])
    assert is_number(req["avg_latency_ms"])
    assert is_number(req["error_rate"])
    assert is_number(req["active_connections"])
  end

  test "dashboard has timestamp after collection" do
    LiveDashboard.collect()
    Process.sleep(500)

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    assert is_binary(dashboard["last_updated"])
    assert {:ok, _, _} = DateTime.from_iso8601(dashboard["last_updated"])
  end

  test "multiple collections increment counter" do
    for _ <- 1..3 do
      LiveDashboard.collect()
      Process.sleep(300)
    end

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    assert dashboard["collection_count"] == 3
  end

  test "metrics change between collections" do
    LiveDashboard.collect()
    Process.sleep(500)
    {:ok, d1} = LiveDashboard.get_dashboard()

    LiveDashboard.collect()
    Process.sleep(500)
    {:ok, d2} = LiveDashboard.get_dashboard()

    assert d2["last_updated"] != d1["last_updated"]
  end

  test "supervisor restarts coordinator after crash" do
    old_pid = Process.whereis(:coordinator)
    Process.exit(old_pid, :kill)
    Process.sleep(500)

    new_pid = Process.whereis(:coordinator)
    assert is_pid(new_pid)
    assert new_pid != old_pid

    Process.sleep(300)
    LiveDashboard.collect()
    Process.sleep(500)

    {:ok, dashboard} = LiveDashboard.get_dashboard()
    assert dashboard["cpu"] != nil
  end
end
