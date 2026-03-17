import Config

config :chat_room, ChatRoom.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [port: 4000],
  server: true,
  secret_key_base: String.duplicate("a", 64)
