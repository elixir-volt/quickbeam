defmodule ChatRoom.Endpoint do
  use Phoenix.Endpoint, otp_app: :chat_room

  socket "/socket", ChatRoom.Socket,
    websocket: true,
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :chat_room,
    only: ~w(index.html)

  plug ChatRoom.Router
end
