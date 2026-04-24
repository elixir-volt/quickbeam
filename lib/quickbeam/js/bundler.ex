defmodule QuickBEAM.JS.Bundler do
  @moduledoc false

  alias NPM.Resolution.PackageResolver

  @ts_extensions [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json"]
  @resolve_opts [extensions: @ts_extensions]

  @spec bundle_file(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bundle_file(entry_path, opts \\ []) do
    entry_path = Path.expand(entry_path)

    bundle_opts =
      opts
      |> Keyword.drop([:node_modules])
      |> Keyword.put_new(:entry, normalize_path(entry_path))

    case collect_modules(entry_path) do
      {:ok, files} -> OXC.bundle(files, bundle_opts)
      {:error, _} = error -> error
    end
  end

  defp collect_modules(entry_path) do
    case do_collect(entry_path, [], MapSet.new()) do
      {:ok, files, _seen} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp do_collect(abs_path, files, seen) do
    if MapSet.member?(seen, abs_path) do
      {:ok, files, seen}
    else
      with {:ok, source} <- File.read(abs_path),
           {:ok, rewritten, resolved_paths} <- rewrite_and_resolve(source, abs_path) do
        seen = MapSet.put(seen, abs_path)
        files = [{normalize_path(abs_path), rewritten} | files]
        collect_deps(resolved_paths, files, seen)
      else
        {:error, reason} when is_atom(reason) -> {:error, {:file_read_error, abs_path, reason}}
        {:error, _} = error -> error
      end
    end
  end

  defp collect_deps([], files, seen), do: {:ok, files, seen}

  defp collect_deps([path | rest], files, seen) do
    case do_collect(path, files, seen) do
      {:ok, files, seen} -> collect_deps(rest, files, seen)
      {:error, _} = error -> error
    end
  end

  defp rewrite_and_resolve(source, importer) do
    Process.put(:bundler_resolved, [])
    from_dir = Path.dirname(importer)

    result =
      OXC.rewrite_specifiers(source, Path.basename(importer), fn specifier ->
        resolve_and_track(specifier, from_dir)
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

  defp resolve_and_track(specifier, from_dir) do
    case PackageResolver.resolve(specifier, from_dir, @resolve_opts) do
      {:builtin, _} ->
        :keep

      {:ok, resolved_path} ->
        Process.put(:bundler_resolved, [resolved_path | Process.get(:bundler_resolved)])

        if PackageResolver.relative?(specifier) do
          :keep
        else
          {:rewrite, normalize_path(resolved_path)}
        end

      :error ->
        throw({:error, {:module_not_found, specifier, "could not resolve"}})
    end
  end

  defp normalize_path(path), do: String.replace(path, "\\", "/")
end
