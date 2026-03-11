defmodule StaticSite.MixProject do
  use Mix.Project

  def project do
    [
      app: :static_site,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:quickbeam, path: "../.."}
    ]
  end
end
