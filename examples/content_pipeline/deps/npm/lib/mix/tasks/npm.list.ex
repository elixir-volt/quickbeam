defmodule Mix.Tasks.Npm.List do
  @shortdoc "List installed npm packages"

  @moduledoc """
  List installed npm packages from `npm.lock`.

      mix npm.list

  Shows direct dependencies (from `package.json`) and their locked versions.
  Transitive dependencies are shown indented.
  """

  use Mix.Task

  @impl true
  def run([]) do
    Mix.Task.run("app.config")

    with {:ok, deps} <- NPM.PackageJSON.read(),
         {:ok, packages} <- NPM.list() do
      if packages == [] do
        Mix.shell().info("No npm packages installed.")
      else
        print_tree(packages, deps)
      end
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix npm.list")
  end

  defp print_tree(packages, deps) do
    direct = Map.keys(deps) |> MapSet.new()

    {direct_pkgs, transitive_pkgs} =
      Enum.split_with(packages, fn {name, _} -> MapSet.member?(direct, name) end)

    Enum.each(direct_pkgs, fn {name, version} ->
      range = Map.get(deps, name, "")
      Mix.shell().info("├── #{name}@#{version} (#{range})")
    end)

    if transitive_pkgs != [] do
      Mix.shell().info("└── #{length(transitive_pkgs)} transitive")

      Enum.each(transitive_pkgs, fn {name, version} ->
        Mix.shell().info("    #{name}@#{version}")
      end)
    end
  end
end
