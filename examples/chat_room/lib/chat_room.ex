defmodule ChatRoom do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ChatRoom.PubSub},
      {Registry, keys: :unique, name: ChatRoom.RoomRegistry},
      {DynamicSupervisor, name: ChatRoom.RoomSupervisor, strategy: :one_for_one},
      ChatRoom.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
