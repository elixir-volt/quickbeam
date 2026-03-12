defmodule NPM.Cache do
  @moduledoc """
  Global package cache.

  Downloaded packages are stored in `~/.npm_ex/cache/<name>/<version>/`
  and reused across projects. The cache is populated on first install
  and checked before downloading from the registry.
  """

  @cache_dir_name ".npm_ex"

  @doc "Root directory of the global cache."
  @spec dir :: String.t()
  def dir do
    System.get_env("NPM_EX_CACHE_DIR") || Path.join(System.user_home!(), @cache_dir_name)
  end

  @doc "Path to a specific package version in the cache."
  @spec package_dir(String.t(), String.t()) :: String.t()
  def package_dir(name, version) do
    Path.join([dir(), "cache", name, version])
  end

  @doc "Check if a package version is already cached."
  @spec cached?(String.t(), String.t()) :: boolean()
  def cached?(name, version) do
    File.exists?(Path.join(package_dir(name, version), "package.json"))
  end

  @doc """
  Ensure a package version is in the cache.

  Downloads and extracts the tarball if not already cached.
  Returns `{:ok, cache_path}` or `{:error, reason}`.
  """
  @spec ensure(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure(name, version, tarball_url, integrity) do
    dest = package_dir(name, version)

    if cached?(name, version) do
      {:ok, dest}
    else
      case NPM.Tarball.fetch_and_extract(tarball_url, integrity, dest) do
        {:ok, _count} -> {:ok, dest}
        error -> error
      end
    end
  end
end
