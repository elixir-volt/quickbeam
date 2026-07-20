defmodule QuickBEAM.Application do
  @moduledoc """
  Starts QuickBEAM's shared OTP services.

  This includes the bounded immutable VM program store and the task supervisor
  used by asynchronous host operations.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: :quickbeam_pg,
        start: {:pg, :start_link, [QuickBEAM.BroadcastChannel]}
      },
      QuickBEAM.LockManager,
      QuickBEAM.WasmAPI,
      QuickBEAM.VM.Program.Store,
      {Task.Supervisor, name: QuickBEAM.VM.TaskSupervisor}
    ]

    QuickBEAM.Storage.init()
    QuickBEAM.Fetch.init()

    opts = [strategy: :one_for_one, name: QuickBEAM.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
