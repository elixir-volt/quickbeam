defmodule NPM.Linker do
  @moduledoc """
  Creates `node_modules` from the global cache.

  Supports multiple linking strategies:
  - `:symlink` (default) — symlinks from `node_modules/pkg` to cache
  - `:copy` — full file copy

  Uses a hoisted layout where packages are placed as high in the tree
  as possible, only nesting when version conflicts occur.
  """

  @type strategy :: :symlink | :copy
  @type resolved :: %{String.t() => NPM.Lockfile.entry()}

  @doc """
  Link all resolved packages into `node_modules`.

  First populates the global cache, then creates the `node_modules` tree.
  """
  @spec link(resolved(), String.t(), strategy()) :: :ok | {:error, term()}
  def link(lockfile, node_modules_dir \\ "node_modules", strategy \\ default_strategy()) do
    with :ok <- populate_cache(lockfile) do
      create_node_modules(lockfile, node_modules_dir, strategy)
    end
  end

  defp populate_cache(lockfile) do
    lockfile
    |> Task.async_stream(
      fn {name, entry} ->
        NPM.Cache.ensure(name, entry.version, entry.tarball, entry.integrity)
      end,
      max_concurrency: 8,
      timeout: 60_000
    )
    |> Enum.reduce(:ok, fn
      {:ok, {:ok, _}}, acc -> acc
      {:ok, {:error, reason}}, _ -> {:error, reason}
      {:exit, reason}, _ -> {:error, reason}
    end)
  end

  defp create_node_modules(lockfile, node_modules_dir, strategy) do
    File.mkdir_p!(node_modules_dir)
    tree = hoist(lockfile)

    Enum.each(tree, fn {name, version} ->
      cache_path = NPM.Cache.package_dir(name, version)
      target = Path.join(node_modules_dir, name)
      link_package(cache_path, target, strategy)
    end)

    :ok
  end

  defp link_package(source, target, :symlink) do
    case Path.dirname(target) |> File.mkdir_p() do
      :ok -> :ok
    end

    File.rm_rf!(target)
    File.ln_s!(source, target)
  end

  defp link_package(source, target, :copy) do
    File.rm_rf!(target)
    File.cp_r!(source, target)
  end

  @doc """
  Hoist packages for a flat `node_modules` layout.

  Returns a list of `{name, version}` tuples representing the top-level
  packages. When multiple versions of a package exist, the most commonly
  depended-on version gets hoisted.
  """
  @spec hoist(resolved()) :: [{String.t(), String.t()}]
  def hoist(lockfile) do
    lockfile
    |> collect_all_packages()
    |> pick_hoisted_versions()
  end

  defp collect_all_packages(lockfile) do
    lockfile
    |> Enum.reduce(%{}, fn {name, entry}, acc ->
      Map.update(acc, name, [entry.version], &[entry.version | &1])
    end)
  end

  defp pick_hoisted_versions(packages) do
    Enum.map(packages, fn {name, versions} ->
      version =
        versions
        |> Enum.frequencies()
        |> Enum.max_by(&elem(&1, 1))
        |> elem(0)

      {name, version}
    end)
  end

  defp default_strategy do
    case :os.type() do
      {:unix, _} -> :symlink
      _ -> :copy
    end
  end
end
