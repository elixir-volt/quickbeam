defmodule CounterLive.MixProject do
  use Mix.Project

  def project do
    [
      app: :counter_live,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [
      mod: {CounterLive, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:quickbeam, path: "../.."},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
