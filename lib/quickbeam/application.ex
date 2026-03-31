defmodule QuickBEAM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: :quickbeam_pg,
        start: {:pg, :start_link, [QuickBEAM.BroadcastChannel]}
      },
      QuickBEAM.LockManager
    ]

    QuickBEAM.Storage.init()
    QuickBEAM.WasmAPI.init()

    opts = [strategy: :one_for_one, name: QuickBEAM.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
