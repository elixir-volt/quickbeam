defmodule QuickBEAM.JS.Bundler do
  @moduledoc false

  @extensions ["", ".ts", ".tsx", ".js", ".jsx"]
  @index_files ["/index.ts", "/index.tsx", "/index.js", "/index.jsx"]

  @doc """
  Bundle an entry file and all its dependencies into a single script.

  Reads the entry file from disk, recursively resolves all imports
  (relative paths and bare specifiers via `node_modules/`), and feeds
  everything to `OXC.bundle/2`.
  """
  @spec bundle_file(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bundle_file(entry_path, opts \\ []) do
    entry_path = Path.expand(entry_path)
    node_modules = opts |> Keyword.get(:node_modules) |> resolve_node_modules(entry_path)
    bundle_opts = Keyword.drop(opts, [:node_modules])

    case collect_modules(entry_path, node_modules) do
      {:ok, files} -> OXC.bundle(files, bundle_opts)
      {:error, _} = error -> error
    end
  end

  defp resolve_node_modules(nil, entry_path), do: find_node_modules(Path.dirname(entry_path))
  defp resolve_node_modules(path, _entry), do: Path.expand(path)

  defp find_node_modules(dir) do
    candidate = Path.join(dir, "node_modules")

    cond do
      File.dir?(candidate) -> candidate
      dir == "/" -> nil
      true -> find_node_modules(Path.dirname(dir))
    end
  end

  defp collect_modules(entry_path, node_modules) do
    basename = Path.basename(entry_path)

    case do_collect(entry_path, basename, node_modules, [], MapSet.new()) do
      {:ok, files, _seen} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp do_collect(abs_path, label, node_modules, files, seen) do
    if MapSet.member?(seen, abs_path) do
      {:ok, files, seen}
    else
      with {:ok, source} <- File.read(abs_path),
           {:ok, specifiers} <- extract_imports(source, abs_path) do
        seen = MapSet.put(seen, abs_path)
        files = [{label, source} | files]
        collect_imports(specifiers, abs_path, node_modules, files, seen)
      else
        {:error, reason} when is_atom(reason) ->
          {:error, {:file_read_error, abs_path, reason}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp extract_imports(source, filename) do
    case OXC.imports(source, Path.basename(filename)) do
      {:ok, specifiers} -> {:ok, specifiers}
      {:error, errors} -> {:error, {:parse_error, filename, errors}}
    end
  end

  defp collect_imports([], _importer, _node_modules, files, seen) do
    {:ok, files, seen}
  end

  defp collect_imports([specifier | rest], importer, node_modules, files, seen) do
    case resolve_specifier(specifier, importer, node_modules) do
      :skip ->
        collect_imports(rest, importer, node_modules, files, seen)

      {:ok, resolved_path} ->
        label = if relative?(specifier), do: Path.basename(resolved_path), else: specifier

        case do_collect(resolved_path, label, node_modules, files, seen) do
          {:ok, files, seen} ->
            collect_imports(rest, importer, node_modules, files, seen)

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_specifier(specifier, importer, node_modules) do
    cond do
      node_builtin?(specifier) -> :skip
      relative?(specifier) -> resolve_relative(specifier, importer)
      true -> resolve_bare(specifier, node_modules)
    end
  end

  defp node_builtin?(specifier), do: String.starts_with?(specifier, "node:")

  defp relative?(specifier),
    do: String.starts_with?(specifier, "./") or String.starts_with?(specifier, "../")

  defp resolve_relative(specifier, importer) do
    base = Path.join(Path.dirname(importer), specifier) |> Path.expand()
    try_resolve(base)
  end

  defp resolve_bare(specifier, nil) do
    {:error, {:module_not_found, specifier, "no node_modules directory found"}}
  end

  defp resolve_bare(specifier, node_modules) do
    {package_name, subpath} = split_package_specifier(specifier)
    package_dir = Path.join(node_modules, package_name)

    if subpath do
      try_resolve(Path.join(package_dir, subpath))
    else
      resolve_package_entry(package_dir, package_name)
    end
  end

  defp split_package_specifier("@" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [scope, name, subpath] -> {"@#{scope}/#{name}", subpath}
      [scope, name] -> {"@#{scope}/#{name}", nil}
      _ -> {"@#{rest}", nil}
    end
  end

  defp split_package_specifier(specifier) do
    case String.split(specifier, "/", parts: 2) do
      [name, subpath] -> {name, subpath}
      [name] -> {name, nil}
    end
  end

  defp resolve_package_entry(package_dir, package_name) do
    pkg_json_path = Path.join(package_dir, "package.json")

    case File.read(pkg_json_path) do
      {:ok, content} ->
        pkg = :json.decode(content)
        entry = resolve_exports_field(pkg) || pkg["module"] || pkg["main"] || "index.js"
        try_resolve(Path.expand(Path.join(package_dir, entry)))

      {:error, _} ->
        {:error, {:module_not_found, package_name, "package not found in node_modules"}}
    end
  end

  defp resolve_exports_field(%{"exports" => exports}) when is_binary(exports), do: exports

  defp resolve_exports_field(%{"exports" => %{"." => entry}}) when is_binary(entry), do: entry

  defp resolve_exports_field(%{"exports" => %{"." => conditions}}) when is_map(conditions) do
    resolve_condition(conditions)
  end

  defp resolve_exports_field(_), do: nil

  defp resolve_condition(value) when is_binary(value), do: value

  defp resolve_condition(value) when is_map(value) do
    (value["import"] || value["default"] || value["require"])
    |> resolve_condition()
  end

  defp resolve_condition(_), do: nil

  defp try_resolve(base) do
    Enum.find_value(@extensions, fn ext ->
      path = base <> ext
      if File.regular?(path), do: {:ok, path}
    end) ||
      Enum.find_value(@index_files, fn idx ->
        path = base <> idx
        if File.regular?(path), do: {:ok, path}
      end) ||
      {:error, {:module_not_found, base, "file not found"}}
  end
end
