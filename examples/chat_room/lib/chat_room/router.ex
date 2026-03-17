defmodule ChatRoom.Router do
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/api/rooms/:room_id" do
    case ChatRoom.Room.get_state(room_id) do
      {:ok, state} -> send_json(conn, 200, state)
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/api/rooms/:room_id/messages" do
    %{"sender" => sender, "text" => text} = conn.body_params

    case ChatRoom.Room.send_message(room_id, sender, text) do
      {:ok, message} -> send_json(conn, 201, message)
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
