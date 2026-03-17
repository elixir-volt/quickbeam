defmodule AIAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :ai_agent,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AIAgent, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:quickbeam, path: "../.."},
      {:jason, "~> 1.4"}
    ]
  end
end
