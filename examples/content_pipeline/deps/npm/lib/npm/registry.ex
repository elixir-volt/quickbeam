defmodule NPM.Registry do
  @moduledoc """
  HTTP client for the npm registry.

  Fetches abbreviated packuments (version list + deps + dist info)
  using the npm registry API.
  """

  @registry_url "https://registry.npmjs.org"

  @type packument :: %{
          name: String.t(),
          versions: %{String.t() => version_info()}
        }

  @type version_info :: %{
          dependencies: %{String.t() => String.t()},
          dist: %{tarball: String.t(), integrity: String.t()}
        }

  @doc "Fetch the abbreviated packument for a package."
  @spec get_packument(String.t()) :: {:ok, packument()} | {:error, term()}
  def get_packument(package) do
    url = "#{@registry_url}/#{encode_package(package)}"

    case Req.get(url, headers: [accept: "application/vnd.npm.install-v1+json"]) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_packument(body)}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_package(package), do: String.replace(package, "/", "%2f")

  defp parse_packument(data) do
    versions =
      for {version_str, info} <- Map.get(data, "versions", %{}), into: %{} do
        {version_str, parse_version_info(info)}
      end

    %{name: Map.get(data, "name", ""), versions: versions}
  end

  defp parse_version_info(info) do
    dist = Map.get(info, "dist", %{})

    %{
      dependencies: Map.get(info, "dependencies", %{}),
      dist: %{
        tarball: Map.get(dist, "tarball", ""),
        integrity: Map.get(dist, "integrity", "")
      }
    }
  end
end
