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
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:crypto, :inets, :ssl, :public_key]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {QuickBEAM.Application, []}
    ]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "credo --strict",
        "ex_dna",
        "cmd zlint lib/quickbeam/*.zig",
        "cmd bun run check",
        "cmd bunx jscpd lib/quickbeam/*.zig priv/ts/*.ts --min-tokens 50 --threshold 0"
      ],
      "js.build": "cmd bun run build",
      "fuzz.sanity": "cmd --cd fuzz zig build test"
    ]
  end

  defp deps do
    [
      {:zigler, "~> 0.15.2", runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false},
      {:nimble_pool, "~> 1.1"},
      {:bandit, "~> 1.0", only: :test},
      {:benchee, "~> 1.3", only: :bench, runtime: false},
      {:quickjs_ex, "~> 0.3.1", only: :bench, runtime: false}
    ]
  end
end
