defmodule NPM.Lockfile do
  @moduledoc """
  Read and write `npm.lock` lockfile.

  The lockfile records resolved versions, integrity hashes, and dependency
  relationships to ensure reproducible installs.
  """

  @default_path "npm.lock"

  @type entry :: %{
          version: String.t(),
          integrity: String.t(),
          tarball: String.t(),
          dependencies: %{String.t() => String.t()}
        }

  @type t :: %{String.t() => entry()}

  @doc "Read the lockfile. Returns empty map if it doesn't exist."
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(path \\ @default_path) do
    case File.read(path) do
      {:ok, content} ->
        data = :json.decode(content)
        lockfile = parse(Map.get(data, "packages", %{}))
        {:ok, lockfile}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Write the lockfile."
  @spec write(t(), String.t()) :: :ok | {:error, term()}
  def write(lockfile, path \\ @default_path) do
    data = %{"lockfileVersion" => 1, "packages" => serialize(lockfile)}
    File.write(path, NPM.JSON.encode_pretty(data))
  end

  defp parse(packages) do
    for {name, info} <- packages, into: %{} do
      {name,
       %{
         version: Map.get(info, "version", ""),
         integrity: Map.get(info, "integrity", ""),
         tarball: Map.get(info, "tarball", ""),
         dependencies: Map.get(info, "dependencies", %{})
       }}
    end
  end

  defp serialize(lockfile) do
    for {name, entry} <- Enum.sort_by(lockfile, &elem(&1, 0)), into: %{} do
      {name,
       %{
         "version" => entry.version,
         "integrity" => entry.integrity,
         "tarball" => entry.tarball,
         "dependencies" => entry.dependencies
       }}
    end
  end
end
