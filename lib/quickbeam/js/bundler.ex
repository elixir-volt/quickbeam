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
    project_root = project_root(entry_path, node_modules)
    entry_label = relative_label(entry_path, project_root)

    bundle_opts =
      opts
      |> Keyword.drop([:node_modules])
      |> Keyword.put_new(:entry, entry_label)

    case collect_modules(entry_path, project_root, node_modules) do
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

  defp collect_modules(entry_path, project_root, node_modules) do
    case do_collect(entry_path, project_root, node_modules, [], MapSet.new()) do
      {:ok, files, _seen} -> {:ok, Enum.reverse(files)}
      {:error, _} = error -> error
    end
  end

  defp do_collect(abs_path, project_root, node_modules, files, seen) do
    if MapSet.member?(seen, abs_path) do
      {:ok, files, seen}
    else
      with {:ok, source} <- File.read(abs_path),
           {:ok, specifiers} <- extract_imports(source, abs_path),
           {:ok, rewritten_source, resolved_paths} <-
             rewrite_bare_imports(source, specifiers, abs_path, project_root, node_modules) do
        seen = MapSet.put(seen, abs_path)
        files = [{relative_label(abs_path, project_root), rewritten_source} | files]
        collect_imports(resolved_paths, project_root, node_modules, files, seen)
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

  defp collect_imports([], _project_root, _node_modules, files, seen), do: {:ok, files, seen}

  defp collect_imports([resolved_path | rest], project_root, node_modules, files, seen) do
    case do_collect(resolved_path, project_root, node_modules, files, seen) do
      {:ok, files, seen} -> collect_imports(rest, project_root, node_modules, files, seen)
      {:error, _} = error -> error
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

  defp rewrite_bare_imports(source, _specifiers, importer, project_root, node_modules) do
    with {:ok, ast} <- OXC.parse(source, Path.basename(importer)),
         {:ok, patches, resolved_paths} <-
           collect_import_patches(ast, importer, project_root, node_modules) do
      {:ok, OXC.patch_string(source, patches), resolved_paths}
    else
      {:error, errors} when is_list(errors) -> {:error, {:parse_error, importer, errors}}
      {:error, _} = error -> error
    end
  end

  defp collect_import_patches(ast, importer, project_root, node_modules) do
    {_ast, {patches, resolved_paths}} =
      OXC.postwalk(ast, {[], []}, fn
        %{type: type, source: %{value: specifier, start: start_pos, end: end_pos}},
        {patches, paths}
        when type in ["ImportDeclaration", "ExportAllDeclaration", "ExportNamedDeclaration"] ->
          case resolve_ast_specifier(specifier, importer, project_root, node_modules) do
            {:ok, nil, nil} ->
              {nil, {patches, paths}}

            {:ok, nil, resolved_path} ->
              {nil, {patches, [resolved_path | paths]}}

            {:ok, replacement, resolved_path} ->
              patch = %{start: start_pos, end: end_pos, change: inspect(replacement)}
              {nil, {[patch | patches], [resolved_path | paths]}}

            {:error, _} = error ->
              throw(error)
          end

        node, acc ->
          {node, acc}
      end)

    {:ok, Enum.reverse(patches), Enum.reverse(resolved_paths)}
  catch
    {:error, _} = error -> error
  end

  defp resolve_ast_specifier(specifier, importer, project_root, node_modules) do
    case resolve_specifier(specifier, importer, node_modules) do
      :skip ->
        {:ok, nil, nil}

      {:ok, resolved_path} ->
        if relative?(specifier) do
          {:ok, nil, resolved_path}
        else
          replacement = relative_import_path(importer, resolved_path, project_root)
          {:ok, replacement, resolved_path}
        end

      {:error, _} = error ->
        error
    end
  end

  defp relative_import_path(importer, resolved_path, project_root) do
    importer_dir = importer |> relative_label(project_root) |> Path.dirname()
    resolved_label = relative_label(resolved_path, project_root)

    Path.relative_to(resolved_label, importer_dir)
    |> ensure_relative_prefix()
    |> String.replace("\\", "/")
  end

  defp ensure_relative_prefix(path) do
    if String.starts_with?(path, ["./", "../"]) do
      path
    else
      "./" <> path
    end
  end

  defp relative_label(path, project_root) do
    Path.relative_to(path, project_root)
    |> String.replace("\\", "/")
  end
end
