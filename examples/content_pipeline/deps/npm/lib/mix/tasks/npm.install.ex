defmodule Mix.Tasks.Npm.Install do
  @shortdoc "Install npm packages"

  @moduledoc """
  Install npm packages.

      mix npm.install                    # Install all deps from package.json
      mix npm.install lodash             # Add latest version
      mix npm.install lodash@^4.0        # Add with specific range
      mix npm.install @types/node@^20    # Add scoped package
      mix npm.install --frozen           # Fail if lockfile is stale (CI)

  Resolves all dependencies using the PubGrub solver, writes `npm.lock`,
  and links packages into `node_modules/`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, positional} = parse_args(args)

    case positional do
      [] -> NPM.install(opts)
      [spec] -> install_spec(spec)
      _ -> Mix.shell().error("Usage: mix npm.install [package[@range]] [--frozen]")
    end
  end

  defp parse_args(args) do
    {parsed, rest, _} = OptionParser.parse(args, strict: [frozen: :boolean])
    {parsed, rest}
  end

  defp install_spec(spec) do
    {name, range} = parse_package_spec(spec)
    NPM.add(name, range)
  end

  @doc false
  def parse_package_spec(spec) do
    case spec do
      # @scope/pkg@range
      "@" <> rest ->
        case String.split(rest, "@", parts: 2) do
          [scoped_name, range] -> {"@" <> scoped_name, range}
          [scoped_name] -> {"@" <> scoped_name, "latest"}
        end

      # pkg@range
      _ ->
        case String.split(spec, "@", parts: 2) do
          [name, range] -> {name, range}
          [name] -> {name, "latest"}
        end
    end
  end
end
