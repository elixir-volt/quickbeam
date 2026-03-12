defmodule Pegasus.MixProject do
  use Mix.Project

  def project do
    [
      app: :pegasus,
      version: "0.2.6",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "peg -> nimbleparsec",
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        github: "https://github.com/ityonemo/pegasus"
      }
    ]
  end

  defp docs do
    [
      main: "Pegasus",
      extras: ["README.md"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/_support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [{:nimble_parsec, "~> 1.2"}, {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}]
  end
end
