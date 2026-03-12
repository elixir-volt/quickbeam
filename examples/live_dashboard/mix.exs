defmodule LiveDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_dashboard,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:quickbeam, path: "../.."}
    ]
  end
end
