defmodule NPM.Resolver do
  @moduledoc """
  `HexSolver.Registry` implementation for npm packages.

  Bridges the npm registry to hex_solver's PubGrub dependency resolver.
  Packuments are cached in an ETS table for the duration of a resolution.
  """

  @behaviour HexSolver.Registry

  @table :npm_resolver_cache

  @doc "Resolve a set of root dependencies to exact versions."
  @spec resolve(%{String.t() => String.t()}) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def resolve(root_deps) when map_size(root_deps) == 0, do: {:ok, %{}}

  def resolve(root_deps) do
    ensure_cache()

    dependencies =
      Enum.map(root_deps, fn {name, range} ->
        {:ok, constraint} = NPMSemver.to_hex_constraint(range)

        %{
          repo: nil,
          name: name,
          constraint: constraint,
          optional: false,
          label: name,
          dependencies: []
        }
      end)

    case HexSolver.run(__MODULE__, dependencies, [], []) do
      {:ok, solution} ->
        result =
          for {name, {version, _repo}} <- solution, into: %{}, do: {name, to_string(version)}

        {:ok, result}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Clear the packument cache."
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.info(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # --- HexSolver.Registry callbacks ---

  @impl true
  def versions(_repo, package) do
    case get_cached_packument(package) do
      {:ok, packument} -> {:ok, parse_sorted_versions(packument)}
      {:error, _} -> :error
    end
  end

  @impl true
  def dependencies(_repo, package, version) do
    case get_cached_packument(package) do
      {:ok, packument} -> deps_for_version(packument, to_string(version))
      {:error, _} -> :error
    end
  end

  @impl true
  def prefetch(packages) do
    packages
    |> Enum.map(fn {_repo, name} -> name end)
    |> Enum.reject(&cached?/1)
    |> Task.async_stream(&fetch_and_cache/1, max_concurrency: 8, timeout: 30_000)
    |> Stream.run()

    :ok
  end

  # --- Helpers ---

  defp parse_sorted_versions(packument) do
    packument.versions
    |> Map.keys()
    |> Enum.flat_map(fn v ->
      case Version.parse(v) do
        {:ok, version} -> [version]
        :error -> []
      end
    end)
    |> Enum.sort(Version)
  end

  defp deps_for_version(packument, version_str) do
    case Map.get(packument.versions, version_str) do
      nil ->
        :error

      info ->
        deps = Enum.flat_map(info.dependencies, &to_solver_dep/1)
        {:ok, deps}
    end
  end

  defp to_solver_dep({name, range}) do
    case NPMSemver.to_hex_constraint(range) do
      {:ok, constraint} ->
        [
          %{
            repo: nil,
            name: name,
            constraint: constraint,
            optional: false,
            label: name,
            dependencies: []
          }
        ]

      :error ->
        []
    end
  end

  # --- Cache ---

  defp ensure_cache do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public])
    end
  end

  defp cached?(package) do
    :ets.info(@table) != :undefined and :ets.member(@table, package)
  end

  defp get_cached_packument(package) do
    ensure_cache()

    case :ets.lookup(@table, package) do
      [{^package, packument}] -> {:ok, packument}
      [] -> fetch_and_cache(package)
    end
  end

  defp fetch_and_cache(package) do
    case NPM.Registry.get_packument(package) do
      {:ok, packument} ->
        :ets.insert(@table, {package, packument})
        {:ok, packument}

      error ->
        error
    end
  end
end
