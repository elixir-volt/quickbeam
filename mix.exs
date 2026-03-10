defmodule QuickBEAM.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :quickbeam,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {QuickBEAM.Application, []}
    ]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "cmd zlint lib/quickbeam/*.zig",
        "cmd bun run check"
      ],
      "js.build": "cmd bun run build",
      "fuzz.sanity": "cmd --cd fuzz zig build test"
    ]
  end

  defp deps do
    [
      {:zigler, "~> 0.15.2", runtime: false}
    ]
  end
end
