defmodule QuickBEAM.MixProject do
  use Mix.Project

  @version "0.10.3"

  @source_url "https://github.com/elixir-volt/quickbeam"

  def project do
    [
      app: :quickbeam,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:crypto, :inets, :ssl, :public_key]],
      name: "QuickBEAM",
      description:
        "JavaScript runtime for the BEAM — Web APIs backed by OTP, native DOM, and a built-in TypeScript toolchain.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      test_coverage: [tool: QuickBEAM.Cover, ignore_modules: [QuickBEAM.Native.Manifest]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key, :xmerl],
      mod: {QuickBEAM.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "credo --strict",
        "ex_dna",
        "cmd zlint lib/quickbeam/*.zig lib/quickbeam/napi/*.zig",
        "cmd npx oxlint -c oxlint.json --type-aware --type-check priv/ts/",
        "cmd npx jscpd lib/quickbeam/*.zig priv/ts/*.ts --min-tokens 50 --threshold 0"
      ],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "ex_dna",
        "cmd zlint lib/quickbeam/*.zig lib/quickbeam/napi/*.zig",
        "cmd npx oxlint -c oxlint.json --type-aware --type-check priv/ts/",
        "cmd npx jscpd lib/quickbeam/*.zig priv/ts/*.ts --min-tokens 50 --threshold 0",
        "test --no-start --exclude napi_addon --exclude napi_sqlite"
      ],
      "fuzz.sanity": "cmd --cd fuzz zig build test"
    ]
  end

  defp deps do
    [
      {:zigler_precompiled, "~> 0.1.2"},
      {:zigler, "~> 0.15.2", runtime: false, optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false},
      {:oxc, ">= 0.7.0"},
      {:npm, "~> 0.5.2"},
      {:mint_web_socket, "~> 1.0"},
      {:nimble_pool, "~> 1.1"},
      {:bandit, "~> 1.0", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:benchee, "~> 1.3", only: :bench, runtime: false},
      {:quickjs_ex, "~> 0.3.1", only: :bench, runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:reach, "~> 1.6", only: :dev, runtime: false},
      {:ex_ast, "~> 0.3", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w[
        lib priv/c_src priv/ts
        mix.exs README.md LICENSE CHANGELOG.md
        checksum-QuickBEAM.Native.exs
        .formatter.exs
      ]
    ]
  end

  defp docs do
    [
      main: "QuickBEAM",
      extras: [
        "README.md",
        "docs/javascript-api.md",
        "docs/architecture.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ["docs/javascript-api.md", "docs/architecture.md"]
      ],
      source_ref: "v#{@version}"
    ]
  end
end
