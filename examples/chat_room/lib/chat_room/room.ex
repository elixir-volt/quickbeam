defmodule ChatRoom.Room do
  @moduledoc """
  A chat room backed by a QuickBEAM runtime.

  Each room is a GenServer (via QuickBEAM) registered by name.
  JS manages the message state; Elixir handles supervision and routing.
  """

  @script Path.expand("../../priv/js/chat-room.ts", __DIR__)

  def child_spec(room_id) do
    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [room_id]},
      restart: :transient
    }
  end

  def start_link(room_id) do
    QuickBEAM.start(
      name: via(room_id),
      script: @script,
      handlers: %{
        "broadcast" => fn [message] ->
          Phoenix.PubSub.broadcast!(ChatRoom.PubSub, "room:#{room_id}", {:new_message, message})
        end
      }
    )
  end

  def send_message(room_id, sender, text) do
    room_id |> ensure_started()
    QuickBEAM.call(via(room_id), "sendMessage", [sender, text])
  end

  def get_history(room_id) do
    room_id |> ensure_started()
    QuickBEAM.call(via(room_id), "getHistory")
  end

  def get_state(room_id) do
    room_id |> ensure_started()
    QuickBEAM.call(via(room_id), "getState")
  end

  defp ensure_started(room_id) do
    case Registry.lookup(ChatRoom.RoomRegistry, room_id) do
      [{_pid, _}] -> :ok
      [] -> DynamicSupervisor.start_child(ChatRoom.RoomSupervisor, {__MODULE__, room_id})
    end
  end

  defp via(room_id) do
    {:via, Registry, {ChatRoom.RoomRegistry, room_id}}
  end
end
