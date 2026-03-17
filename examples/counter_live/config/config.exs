import Config

config :counter_live, CounterLive.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [port: 4000],
  server: true,
  live_view: [signing_salt: "quickbeam_counter"],
  secret_key_base: String.duplicate("a", 64)
