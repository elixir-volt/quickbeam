defmodule Mix.Tasks.Npm.Get do
  @shortdoc "Fetch locked npm packages"

  @moduledoc """
  Fetch npm packages from `npm.lock` without re-resolving.

      mix npm.get

  Downloads any packages that are not already present in `deps/npm/`.
  Run `mix npm.install` to resolve and update the lockfile.
  """

  use Mix.Task

  @impl true
  def run([]) do
    Mix.Task.run("app.config")
    NPM.get()
  end

  def run(_) do
    Mix.shell().error("Usage: mix npm.get")
  end
end
