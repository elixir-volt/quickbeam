defmodule QuickBEAM.JS.PackageResolver do
  @moduledoc false

  alias QuickBEAM.JS.Exports

  @node_builtins ~w(
    assert async_hooks buffer child_process cluster console constants
    crypto dgram diagnostics_channel dns domain events fs http http2
    https inspector module net os path perf_hooks process punycode
    querystring readline repl stream string_decoder sys timers tls
    trace_events tty url util v8 vm wasi worker_threads zlib
  )

  @default_extensions [".js", ".mjs", ".cjs", ".json"]

  @spec relative?(String.t()) :: boolean()
  def relative?("." <> _), do: true
  def relative?("/" <> _), do: true
  def relative?(_), do: false

  @spec node_builtin?(String.t()) :: boolean()
  def node_builtin?("node:" <> _), do: true
  def node_builtin?(name), do: name in @node_builtins

  @spec split_specifier(String.t()) :: {String.t(), String.t() | nil}
  def split_specifier("@" <> _ = specifier) do
    case String.split(specifier, "/", parts: 3) do
      [scope, name, subpath] -> {"#{scope}/#{name}", "./#{subpath}"}
      [scope, name] -> {"#{scope}/#{name}", nil}
      _ -> {specifier, nil}
    end
  end

  def split_specifier(specifier) do
    case String.split(specifier, "/", parts: 2) do
      [name, subpath] -> {name, "./#{subpath}"}
      [name] -> {name, nil}
    end
  end

  @spec find_node_modules(String.t()) :: String.t() | nil
  def find_node_modules(dir) do
    dir = Path.expand(dir)
    candidate = Path.join(dir, "node_modules")

    cond do
      File.dir?(candidate) -> candidate
      dir == "/" -> nil
      true -> find_node_modules(Path.dirname(dir))
    end
  end

  @spec try_resolve(String.t(), keyword()) :: {:ok, String.t()} | :error
  def try_resolve(base, opts \\ []) do
    extensions = Keyword.get(opts, :extensions, @default_extensions)

    with :error <- try_exact(base),
         :error <- try_extensions(base, extensions) do
      try_index(base, extensions)
    end
  end

  @spec resolve_entry(String.t(), keyword()) :: {:ok, String.t()} | :error
  def resolve_entry(package_dir, opts \\ []) do
    subpath = Keyword.get(opts, :subpath, ".")
    conditions = Keyword.get(opts, :conditions, ["import", "default"])
    extensions = Keyword.get(opts, :extensions, @default_extensions)
    pkg_json_path = Path.join(package_dir, "package.json")

    case read_package_json(pkg_json_path) do
      {:ok, pkg} -> resolve_from_pkg(pkg, package_dir, subpath, conditions, extensions)
      :error -> try_resolve(Path.join(package_dir, "index"), extensions: extensions)
    end
  end

  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:builtin, String.t()} | :error
  def resolve(specifier, from_dir, opts \\ []) do
    cond do
      node_builtin?(specifier) ->
        {:builtin, specifier}

      String.starts_with?(specifier, "#") ->
        resolve_package_import(specifier, from_dir, opts)

      relative?(specifier) ->
        specifier
        |> Path.expand(from_dir)
        |> try_resolve(opts)

      true ->
        resolve_bare(specifier, from_dir, opts)
    end
  end

  @spec relative_import_path(String.t(), String.t(), String.t()) :: String.t()
  def relative_import_path(importer, target, project_root) do
    importer_dir = importer |> Path.relative_to(project_root) |> Path.dirname()
    target_label = Path.relative_to(target, project_root)

    target_label
    |> Path.relative_to(importer_dir)
    |> ensure_relative_prefix()
  end

  @spec nearest_package(String.t()) :: {:ok, String.t(), map()} | :error
  def nearest_package(dir) do
    dir = Path.expand(dir)
    package_json_path = Path.join(dir, "package.json")

    cond do
      File.regular?(package_json_path) ->
        with {:ok, package} <- read_package_json(package_json_path), do: {:ok, dir, package}

      dir == "/" or Path.basename(dir) == "node_modules" ->
        :error

      true ->
        nearest_package(Path.dirname(dir))
    end
  end

  @spec package_root(String.t(), String.t()) :: {:ok, String.t()} | :error
  def package_root(package_name, from_dir) do
    case find_node_modules(from_dir) do
      nil ->
        :error

      node_modules ->
        package_dir = Path.join(node_modules, package_name)
        if File.dir?(package_dir), do: {:ok, package_dir}, else: :error
    end
  end

  defp ensure_relative_prefix("./" <> _ = path), do: path
  defp ensure_relative_prefix("../" <> _ = path), do: path
  defp ensure_relative_prefix(path), do: "./" <> path

  defp resolve_package_import(specifier, from_dir, opts) do
    conditions = Keyword.get(opts, :conditions, ["import", "default"])
    extensions = Keyword.get(opts, :extensions, @default_extensions)

    with {:ok, package_dir, %{"imports" => imports}} <- nearest_package(from_dir),
         {:ok, target} <- Exports.resolve(imports, specifier, conditions) do
      package_dir
      |> expand_target(target)
      |> try_resolve(extensions: extensions)
    else
      _ -> :error
    end
  end

  defp resolve_bare(specifier, from_dir, opts) do
    {package_name, subpath} = split_specifier(specifier)

    with {:ok, package_dir} <- package_root(package_name, from_dir) do
      opts
      |> Keyword.put(:subpath, subpath || ".")
      |> then(&resolve_entry(package_dir, &1))
    end
  end

  defp resolve_from_pkg(pkg, package_dir, subpath, conditions, extensions) do
    with :error <- resolve_via_exports(pkg, package_dir, subpath, conditions),
         :error <- resolve_via_fields(pkg, package_dir, subpath, conditions, extensions) do
      try_resolve(Path.join(package_dir, "index"), extensions: extensions)
    end
  end

  defp resolve_via_exports(pkg, package_dir, subpath, conditions) do
    case Exports.parse(pkg) do
      nil ->
        :error

      export_map ->
        case Exports.resolve(export_map, subpath, conditions) do
          {:ok, target} -> ensure_file(package_dir, target)
          :error -> :error
        end
    end
  end

  defp resolve_via_fields(_pkg, _package_dir, subpath, _conditions, _extensions)
       when subpath != "." do
    :error
  end

  defp resolve_via_fields(pkg, package_dir, ".", conditions, extensions) do
    fields =
      if "browser" in conditions, do: ["browser", "module", "main"], else: ["module", "main"]

    Enum.find_value(fields, :error, fn field ->
      case Map.get(pkg, field) do
        nil -> nil
        target when is_binary(target) -> resolve_field_target(package_dir, target, extensions)
        _ -> nil
      end
    end)
  end

  defp resolve_field_target(package_dir, target, extensions) do
    full = expand_target(package_dir, target)

    case try_resolve(full, extensions: extensions) do
      {:ok, _} = ok -> ok
      :error -> nil
    end
  end

  defp ensure_file(package_dir, target) do
    package_dir
    |> expand_target(target)
    |> try_resolve(extensions: [""])
  end

  defp expand_target(package_dir, "./" <> rest), do: Path.join(package_dir, rest)
  defp expand_target(package_dir, target), do: Path.join(package_dir, target)

  defp try_exact(path) do
    if File.regular?(path), do: {:ok, path}, else: :error
  end

  defp try_extensions(base, extensions) do
    Enum.find_value(extensions, :error, fn ext ->
      path = base <> ext
      if File.regular?(path), do: {:ok, path}
    end)
  end

  defp try_index(base, extensions) do
    if File.dir?(base), do: try_extensions(Path.join(base, "index"), extensions), else: :error
  end

  defp read_package_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, package} <- Jason.decode(content) do
      {:ok, package}
    else
      _ -> :error
    end
  end
end
