defmodule CounterLive.Endpoint do
  use Phoenix.Endpoint, otp_app: :counter_live

  @session_options [
    store: :cookie,
    key: "_counter_live_key",
    signing_salt: "quickbeam"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug CounterLive.Router
end
