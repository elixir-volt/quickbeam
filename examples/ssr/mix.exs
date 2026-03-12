defmodule SSR.MixProject do
  use Mix.Project

  def project do
    [
      app: :ssr,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:quickbeam, path: "../.."},
      {:bandit, "~> 1.0"}
    ]
  end
end
