defmodule QuickBEAM.JS.Bundler do
  @moduledoc false

  alias NPM.PackageResolver

  @ts_extensions [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json"]
  @resolve_opts [extensions: @ts_extensions]

  @spec bundle_file(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bundle_file(entry_path, opts \\ []) do
    entry_path = Path.expand(entry_path)
    node_modules = Keyword.get(opts, :node_modules) || find_node_modules(entry_path)
    project_root = project_root(entry_path, node_modules)
    entry_label = Path.relative_to(entry_path, project_root, separator: "/")

    bundle_opts =
      opts
      |> Keyword.drop([:node_modules])
      |> Keyword.put_new(:entry, entry_label)

    case collect_modules(entry_path, project_root) do
      {:ok, files} -> OXC.bundle(files, bundle_opts)
      {:error, _} = error -> error
    end
  end

  defp collect_modules(entry_path, project_root) do
    case do_collect(entry_path, project_root, [], MapSet.new()) do
      {:ok, files, _seen} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp do_collect(abs_path, project_root, files, seen) do
    if MapSet.member?(seen, abs_path) do
      {:ok, files, seen}
    else
      with {:ok, source} <- File.read(abs_path),
           {:ok, rewritten, resolved_paths} <- rewrite_and_resolve(source, abs_path, project_root) do
        label = Path.relative_to(abs_path, project_root, separator: "/")
        seen = MapSet.put(seen, abs_path)
        files = [{label, rewritten} | files]
        collect_deps(resolved_paths, project_root, files, seen)
      else
        {:error, reason} when is_atom(reason) -> {:error, {:file_read_error, abs_path, reason}}
        {:error, _} = error -> error
      end
    end
  end

  defp collect_deps([], _project_root, files, seen), do: {:ok, files, seen}

  defp collect_deps([path | rest], project_root, files, seen) do
    case do_collect(path, project_root, files, seen) do
      {:ok, files, seen} -> collect_deps(rest, project_root, files, seen)
      {:error, _} = error -> error
    end
  end

  defp rewrite_and_resolve(source, importer, project_root) do
    Process.put(:bundler_resolved, [])
    from_dir = Path.dirname(importer)

    result =
      OXC.rewrite_specifiers(source, Path.basename(importer), fn specifier ->
        resolve_and_track(specifier, from_dir, project_root)
      end)

    resolved_paths = Process.delete(:bundler_resolved) || []

    case result do
      {:ok, rewritten} -> {:ok, rewritten, Enum.reverse(resolved_paths)}
      {:error, errors} -> {:error, {:parse_error, importer, errors}}
    end
  catch
    {:error, _} = error ->
      Process.delete(:bundler_resolved)
      error
  end

  defp resolve_and_track(specifier, from_dir, project_root) do
    case PackageResolver.resolve(specifier, from_dir, @resolve_opts) do
      {:builtin, _} ->
        :keep

      {:ok, resolved_path} ->
        Process.put(:bundler_resolved, [resolved_path | Process.get(:bundler_resolved)])

        if PackageResolver.relative?(specifier) do
          :keep
        else
          {:rewrite, PackageResolver.relative_import_path(from_dir, resolved_path, project_root)}
        end

      :error ->
        throw({:error, {:module_not_found, specifier, "could not resolve"}})
    end
  end

  defp find_node_modules(entry_path) do
    PackageResolver.find_node_modules(Path.dirname(entry_path))
  end

  defp project_root(entry_path, nil), do: Path.dirname(entry_path)

  defp project_root(entry_path, node_modules) do
    [entry_path, node_modules]
    |> Enum.map(&Path.split/1)
    |> shared_segments()
    |> Path.join()
  end

  defp shared_segments([first | rest]) do
    first
    |> Enum.with_index()
    |> Enum.take_while(fn {segment, index} ->
      Enum.all?(rest, &(Enum.at(&1, index) == segment))
    end)
    |> Enum.map(&elem(&1, 0))
  end
end
