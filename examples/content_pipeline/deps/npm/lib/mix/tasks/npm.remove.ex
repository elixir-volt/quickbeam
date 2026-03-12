defmodule Mix.Tasks.Npm.Remove do
  @shortdoc "Remove an npm package"

  @moduledoc """
  Remove an npm package from `package.json` and re-install.

      mix npm.remove lodash
      mix npm.remove @types/node
  """

  use Mix.Task

  @impl true
  def run([name]) do
    Mix.Task.run("app.config")

    case NPM.remove(name) do
      :ok ->
        :ok

      {:error, {:not_found, ^name}} ->
        Mix.shell().error("Package #{name} not found in package.json.")

      {:error, reason} ->
        Mix.shell().error("Failed to remove #{name}: #{inspect(reason)}")
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix npm.remove <package>")
  end
end
