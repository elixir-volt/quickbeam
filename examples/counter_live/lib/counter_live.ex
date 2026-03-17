defmodule CounterLive do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {QuickBEAM.ContextPool, name: CounterLive.JSPool, size: 2, apis: false},
      CounterLive.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
