defmodule QuickBEAM.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :quickbeam,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {QuickBEAM.Application, []}
    ]
  end

  defp deps do
    [
      {:zigler, "~> 0.15.2", runtime: false},
      {:jason, "~> 1.4"}
    ]
  end
end
