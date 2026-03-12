defmodule LiveDashboard do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    js_dir = Keyword.get(opts, :js_dir, Path.join(:code.priv_dir(:live_dashboard), "js"))

    children = [
      {QuickBEAM,
       name: :coordinator,
       script: Path.join(js_dir, "coordinator.js")}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def collect do
    QuickBEAM.call(:coordinator, "collectMetrics")
  end

  def get_dashboard do
    QuickBEAM.call(:coordinator, "getDashboard")
  end

  def worker_count do
    QuickBEAM.call(:coordinator, "getWorkerCount")
  end
end
