defmodule ChatRoom.RoomTest do
  use ExUnit.Case, async: false

  setup do
    room_id = "test-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup_room(room_id) end)
    %{room_id: room_id}
  end

  test "send and retrieve messages", %{room_id: room_id} do
    {:ok, msg} = ChatRoom.Room.send_message(room_id, "Alice", "Hello!")
    assert msg["sender"] == "Alice"
    assert msg["text"] == "Hello!"
    assert is_number(msg["timestamp"])

    {:ok, msg2} = ChatRoom.Room.send_message(room_id, "Bob", "Hi Alice!")

    {:ok, history} = ChatRoom.Room.get_history(room_id)
    assert length(history) == 2
    assert Enum.at(history, 0)["sender"] == "Alice"
    assert Enum.at(history, 1)["sender"] == "Bob"
    assert msg2["timestamp"] >= msg["timestamp"]
  end

  test "separate rooms have separate state", %{room_id: room_id} do
    other_room = "#{room_id}-other"
    on_exit(fn -> cleanup_room(other_room) end)

    {:ok, _} = ChatRoom.Room.send_message(room_id, "Alice", "Room 1")
    {:ok, _} = ChatRoom.Room.send_message(other_room, "Bob", "Room 2")

    {:ok, h1} = ChatRoom.Room.get_history(room_id)
    {:ok, h2} = ChatRoom.Room.get_history(other_room)

    assert length(h1) == 1
    assert length(h2) == 1
    assert hd(h1)["text"] == "Room 1"
    assert hd(h2)["text"] == "Room 2"
  end

  test "broadcasts via PubSub", %{room_id: room_id} do
    Phoenix.PubSub.subscribe(ChatRoom.PubSub, "room:#{room_id}")

    {:ok, _} = ChatRoom.Room.send_message(room_id, "Alice", "broadcast test")

    assert_receive {:new_message, msg}, 1000
    assert msg["sender"] == "Alice"
    assert msg["text"] == "broadcast test"
  end

  test "room state", %{room_id: room_id} do
    {:ok, state} = ChatRoom.Room.get_state(room_id)
    assert state["messageCount"] == 0

    {:ok, _} = ChatRoom.Room.send_message(room_id, "Alice", "one")
    {:ok, _} = ChatRoom.Room.send_message(room_id, "Bob", "two")

    {:ok, state} = ChatRoom.Room.get_state(room_id)
    assert state["messageCount"] == 2
  end

  test "room survives restart", %{room_id: room_id} do
    {:ok, _} = ChatRoom.Room.send_message(room_id, "Alice", "before crash")

    [{pid, _}] = Registry.lookup(ChatRoom.RoomRegistry, room_id)
    Process.exit(pid, :kill)
    Process.sleep(50)

    # Room is gone after kill (transient restart)
    # Sending a new message creates a fresh room
    {:ok, _} = ChatRoom.Room.send_message(room_id, "Bob", "after restart")
    {:ok, history} = ChatRoom.Room.get_history(room_id)

    # Fresh room — only the new message
    assert length(history) == 1
    assert hd(history)["sender"] == "Bob"
  end

  defp cleanup_room(room_id) do
    case Registry.lookup(ChatRoom.RoomRegistry, room_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end
end
