defmodule Protoss.MixProject do
  use Mix.Project

  def project do
    [
      app: :protoss,
      version: "1.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  @source_url "https://github.com/ityonemo/protoss"

  defp package do
    [
      description: "Protoss is an evil, powerful Protocol library.",
      licenses: ["MIT"],
      files: ~w[lib .formatter.exs mix.exs README.md LICENSE.md],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev}
    ]
  end

    defp docs do
      [
        main: "Protoss",
        extras: ["README.md"]
      ]
    end
  
end
