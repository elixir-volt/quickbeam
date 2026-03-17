defmodule AIAgent do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AIAgent.AgentRegistry},
      {DynamicSupervisor, name: AIAgent.AgentSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
