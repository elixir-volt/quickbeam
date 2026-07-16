defmodule QuickBEAM.MixProject do
  use Mix.Project

  @version "0.10.19"

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
        "cmd sh -c \"npx jscpd priv/ts/*.ts --min-tokens 50 --threshold 0\""
      ],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "ex_dna",
        "cmd zlint lib/quickbeam/*.zig lib/quickbeam/napi/*.zig",
        "cmd npx oxlint -c oxlint.json --type-aware --type-check priv/ts/",
        "cmd sh -c \"npx jscpd priv/ts/*.ts --min-tokens 50 --threshold 0\"",
        "test --no-start --exclude napi_addon --exclude napi_sqlite"
      ],
      "fuzz.sanity": "cmd --cd fuzz zig build test"
    ]
  end

  defp deps do
    [
      {:zigler_precompiled, "~> 0.1.4"},
      {:zigler, "~> 0.15.2", runtime: false, optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      {:json_codec, "~> 0.2.2", only: :test},
      {:yaml_elixir, "~> 2.12", only: :test},
      {:varint, "~> 1.6"},
      {:oxc, "~> 0.17.2"},
      {:npm, "~> 0.7.5", optional: true},
      {:mint_web_socket, "~> 1.0"},
      {:nimble_pool, "~> 1.1"},
      {:bandit, "~> 1.0", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:benchee, "~> 1.3", only: :bench, runtime: false},
      {:quickjs_ex, "~> 0.3.1", only: :bench, runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
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
        "docs/beam-interpreter-architecture.md",
        "docs/beam-compiler-contract.md",
        "docs/beam-compiler-performance-measurements.md",
        "docs/beam-compiler-scheduler-measurements.md",
        "docs/beam-compiler-scalar-scheduler-measurements.md",
        "docs/beam-compiler-ssr-measurements.md",
        "docs/beam-compiler-scalar-ssr-measurements.md",
        "docs/beam-scheduler-measurements.md",
        "docs/beam-ssr-measurements.md",
        "docs/prototype-delta-audit.md",
        "docs/test262-conformance.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: [
          "docs/javascript-api.md",
          "docs/architecture.md",
          "docs/beam-interpreter-architecture.md",
          "docs/beam-object-memory-investigation.md",
          "docs/beam-object-memory-measurements.md",
          "docs/beam-compiler-contract.md",
          "docs/beam-compiler-performance-measurements.md",
          "docs/beam-compiler-region-investigation.md",
          "docs/beam-compiler-region-probe.md",
          "docs/beam-compiler-region-hotspots.md",
          "docs/beam-compiler-region-ssr-measurements.md",
          "docs/beam-compiler-scheduler-measurements.md",
          "docs/beam-compiler-scalar-scheduler-measurements.md",
          "docs/beam-compiler-ssr-measurements.md",
          "docs/beam-compiler-scalar-ssr-measurements.md",
          "docs/beam-scheduler-measurements.md",
          "docs/beam-ssr-measurements.md",
          "docs/prototype-delta-audit.md",
          "docs/test262-conformance.md"
        ]
      ],
      filter_modules: &documented_module?/2,
      skip_code_autolink_to: &skip_doc_warning?/1,
      skip_undefined_reference_warnings_on: &skip_doc_warning?/1,
      source_ref: "v#{@version}"
    ]
  end

  defp skip_doc_warning?(reference) when not is_binary(reference), do: false

  defp skip_doc_warning?(reference) do
    internal_vm_modules = [
      "QuickBEAM.VM.Async",
      "QuickBEAM.VM.Builtin",
      "QuickBEAM.VM.Compiler",
      "QuickBEAM.VM.Exceptions",
      "QuickBEAM.VM.Fuzz",
      "QuickBEAM.VM.Invocation",
      "QuickBEAM.VM.Iterator",
      "QuickBEAM.VM.Opcodes",
      "QuickBEAM.VM.Properties",
      "QuickBEAM.VM.Value"
    ]

    String.starts_with?(reference, "QuickBEAM.Runtime") or
      Enum.any?(internal_vm_modules, &String.starts_with?(reference, &1)) or
      String.ends_with?(reference, "beam-interpreter-architecture.md")
  end

  defp documented_module?(module, _metadata) do
    public_vm_modules = [
      QuickBEAM.VM.ABI,
      QuickBEAM.VM.ClosureVariable,
      QuickBEAM.VM.Compiler,
      QuickBEAM.VM.Function,
      QuickBEAM.VM.Measurement,
      QuickBEAM.VM.Program,
      QuickBEAM.VM.SourcePosition,
      QuickBEAM.VM.Variable
    ]

    not String.starts_with?(inspect(module), "QuickBEAM.VM.") or module in public_vm_modules
  end
end
