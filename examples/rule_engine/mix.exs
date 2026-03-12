defmodule RuleEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :rule_engine,
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
