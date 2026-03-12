defmodule NPM.PackageJSON do
  @moduledoc """
  Read and write `package.json` files.
  """

  @default_path "package.json"

  @doc "Read dependencies from `package.json`."
  @spec read(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def read(path \\ @default_path) do
    case File.read(path) do
      {:ok, content} ->
        data = :json.decode(content)
        {:ok, Map.get(data, "dependencies", %{})}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Add a dependency to `package.json`, creating the file if needed."
  @spec add_dep(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_dep(name, range, path \\ @default_path) do
    data = read_raw(path)
    deps = Map.get(data, "dependencies", %{})
    updated = Map.put(data, "dependencies", Map.put(deps, name, range))

    File.write(path, NPM.JSON.encode_pretty(updated))
  end

  @doc "Remove a dependency from `package.json`."
  @spec remove_dep(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_dep(name, path \\ @default_path) do
    data = read_raw(path)
    deps = Map.get(data, "dependencies", %{})

    if Map.has_key?(deps, name) do
      updated = Map.put(data, "dependencies", Map.delete(deps, name))
      File.write(path, NPM.JSON.encode_pretty(updated))
    else
      {:error, {:not_found, name}}
    end
  end

  defp read_raw(path) do
    case File.read(path) do
      {:ok, content} -> :json.decode(content)
      {:error, :enoent} -> %{}
    end
  end
end
