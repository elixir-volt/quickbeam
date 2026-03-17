defmodule ChatRoom.RoomChannel do
  use Phoenix.Channel

  @impl true
  def join("room:" <> room_id, _params, socket) do
    Phoenix.PubSub.subscribe(ChatRoom.PubSub, "room:#{room_id}")

    case ChatRoom.Room.get_history(room_id) do
      {:ok, messages} ->
        socket = assign(socket, :room_id, room_id)
        {:ok, %{messages: messages}, socket}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("send_message", %{"sender" => sender, "text" => text}, socket) do
    case ChatRoom.Room.send_message(socket.assigns.room_id, sender, text) do
      {:ok, message} ->
        {:reply, {:ok, message}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    push(socket, "new_message", message)
    {:noreply, socket}
  end
end
