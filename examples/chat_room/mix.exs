defmodule ChatRoom.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat_room,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ChatRoom, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:quickbeam, path: "../.."},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
