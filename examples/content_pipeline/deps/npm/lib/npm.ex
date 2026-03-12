defmodule NPM do
  @moduledoc """
  npm package manager for Elixir.

  Resolves, fetches, and installs npm packages using Mix tasks.
  Dependencies are declared in `package.json` and locked in `npm.lock`.

  ## Mix tasks

      mix npm.install              # Install all deps from package.json
      mix npm.install lodash       # Add latest version
      mix npm.install lodash@^4.0  # Add with specific range
      mix npm.install --frozen     # Fail if lockfile is stale (CI mode)
      mix npm.get                  # Fetch locked deps without resolving
      mix npm.remove lodash        # Remove a package
      mix npm.list                 # List installed packages

  Packages are cached globally in `~/.npm_ex/cache/` and linked into
  `node_modules/` via symlinks (macOS/Linux) or copies (Windows).
  """

  @node_modules "node_modules"

  @doc """
  Install all dependencies from `package.json`.

  ## Options

    * `:frozen` - when `true`, fails if `npm.lock` doesn't match
      `package.json` instead of re-resolving. Useful for CI.
  """
  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts \\ []) do
    case NPM.PackageJSON.read() do
      {:ok, deps} -> do_install(deps, opts)
      error -> error
    end
  end

  @doc """
  Add a package to `package.json` and install all dependencies.
  """
  @spec add(String.t(), String.t()) :: :ok | {:error, term()}
  def add(name, range \\ "latest") do
    range = if range == "latest", do: resolve_latest(name), else: range

    with range_str when is_binary(range_str) <- range,
         :ok <- NPM.PackageJSON.add_dep(name, range_str),
         {:ok, deps} <- NPM.PackageJSON.read() do
      do_install(deps, [])
    end
  end

  @doc """
  Remove a package from `package.json` and re-install.
  """
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(name) do
    with :ok <- NPM.PackageJSON.remove_dep(name),
         {:ok, deps} <- NPM.PackageJSON.read() do
      do_install(deps, [])
    end
  end

  @doc """
  Fetch locked dependencies without re-resolving.

  Reads `npm.lock` and populates the global cache and `node_modules/`
  for any missing packages.
  """
  @spec get :: :ok | {:error, term()}
  def get do
    case NPM.Lockfile.read() do
      {:ok, lockfile} when lockfile == %{} ->
        Mix.shell().info("No npm.lock found, run `mix npm.install` first.")
        :ok

      {:ok, lockfile} ->
        link_from_lockfile(lockfile)

      error ->
        error
    end
  end

  @doc """
  List installed packages with versions.

  Returns a list of `{name, version}` tuples.
  """
  @spec list :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list do
    case NPM.Lockfile.read() do
      {:ok, lockfile} when lockfile == %{} ->
        {:ok, []}

      {:ok, lockfile} ->
        packages =
          lockfile
          |> Enum.map(fn {name, entry} -> {name, entry.version} end)
          |> Enum.sort_by(&elem(&1, 0))

        {:ok, packages}

      error ->
        error
    end
  end

  # --- Private ---

  defp do_install(deps, _opts) when map_size(deps) == 0 do
    Mix.shell().info("No npm dependencies found in package.json.")
    :ok
  end

  defp do_install(deps, opts) do
    if opts[:frozen] do
      frozen_install(deps)
    else
      full_install(deps)
    end
  end

  defp frozen_install(deps) do
    case NPM.Lockfile.read() do
      {:ok, lockfile} when lockfile == %{} ->
        Mix.shell().error("npm.lock not found. Run `mix npm.install` first.")
        {:error, :no_lockfile}

      {:ok, lockfile} ->
        if lockfile_matches?(lockfile, deps) do
          link_from_lockfile(lockfile)
        else
          Mix.shell().error(
            "npm.lock is out of date with package.json.\n" <>
              "Run `mix npm.install` to update the lockfile."
          )

          {:error, :frozen_lockfile}
        end

      error ->
        error
    end
  end

  defp lockfile_matches?(lockfile, deps) do
    Enum.all?(deps, fn {name, _range} ->
      Map.has_key?(lockfile, name)
    end) and
      Enum.all?(lockfile, fn {name, _entry} ->
        Map.has_key?(deps, name) or
          Enum.any?(lockfile, fn {_, e} -> Map.has_key?(e.dependencies, name) end)
      end)
  end

  defp full_install(deps) do
    {resolve_us, result} =
      :timer.tc(fn ->
        NPM.Resolver.clear_cache()
        NPM.Resolver.resolve(deps)
      end)

    case result do
      {:ok, resolved} ->
        Mix.shell().info("Resolved #{map_size(resolved)} packages in #{format_ms(resolve_us)}")

        lockfile = build_lockfile(resolved)
        NPM.Lockfile.write(lockfile)
        link_from_lockfile(lockfile)

      {:error, message} ->
        Mix.shell().error("Resolution failed:\n#{message}")
        {:error, :resolution_failed}
    end
  end

  defp link_from_lockfile(lockfile) do
    cached = Enum.count(lockfile, fn {name, entry} -> NPM.Cache.cached?(name, entry.version) end)
    to_fetch = map_size(lockfile) - cached

    if to_fetch > 0 do
      Mix.shell().info("Fetching #{to_fetch} package#{if to_fetch != 1, do: "s", else: ""}...")
    end

    {link_us, result} = :timer.tc(fn -> NPM.Linker.link(lockfile, @node_modules) end)

    case result do
      :ok ->
        count = map_size(lockfile)

        Mix.shell().info(
          "Installed #{count} package#{if count != 1, do: "s", else: ""} in #{format_ms(link_us)}"
        )

        :ok

      error ->
        error
    end
  end

  defp build_lockfile(resolved) do
    for {name, version_str} <- resolved, into: %{} do
      {:ok, packument} = NPM.Registry.get_packument(name)
      info = Map.fetch!(packument.versions, version_str)

      {name,
       %{
         version: version_str,
         integrity: info.dist.integrity,
         tarball: info.dist.tarball,
         dependencies: info.dependencies
       }}
    end
  end

  defp resolve_latest(name) do
    case NPM.Registry.get_packument(name) do
      {:ok, packument} -> latest_stable_range(packument)
      {:error, reason} -> {:error, reason}
    end
  end

  defp latest_stable_range(packument) do
    packument.versions
    |> Map.keys()
    |> Enum.flat_map(&parse_stable_version/1)
    |> Enum.sort(Version)
    |> List.last()
    |> case do
      nil -> {:error, :no_versions}
      v -> "^#{v}"
    end
  end

  defp parse_stable_version(v) do
    case Version.parse(v) do
      {:ok, ver} -> if ver.pre == [], do: [ver], else: []
      :error -> []
    end
  end

  defp format_ms(microseconds) do
    ms = div(microseconds, 1000)
    if ms < 1000, do: "#{ms}ms", else: "#{Float.round(ms / 1000, 1)}s"
  end
end
