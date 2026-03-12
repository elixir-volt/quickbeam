defmodule NPM.Tarball do
  @moduledoc """
  Download and extract npm package tarballs.

  Verifies SHA-512 integrity and extracts contents to disk.
  """

  @doc """
  Download a tarball, verify its integrity, and extract to a directory.

  Returns `{:ok, file_count}` or `{:error, reason}`.
  """
  @spec fetch_and_extract(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fetch_and_extract(tarball_url, integrity, dest_dir) do
    case Req.get(tarball_url, decode_body: false) do
      {:ok, %{status: 200, body: body}} ->
        with :ok <- verify_integrity(body, integrity) do
          extract(body, dest_dir)
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Verify SHA-512 integrity of a binary against an SRI hash."
  @spec verify_integrity(binary(), String.t()) :: :ok | {:error, :integrity_mismatch}
  def verify_integrity(_body, ""), do: :ok

  def verify_integrity(body, "sha512-" <> expected_b64) do
    actual = :crypto.hash(:sha512, body) |> Base.encode64()
    if actual == expected_b64, do: :ok, else: {:error, :integrity_mismatch}
  end

  def verify_integrity(body, "sha1-" <> expected_b64) do
    actual = :crypto.hash(:sha, body) |> Base.encode64()
    if actual == expected_b64, do: :ok, else: {:error, :integrity_mismatch}
  end

  def verify_integrity(_body, _unknown), do: :ok

  @doc """
  Extract a `.tgz` tarball into a destination directory.

  Strips the `package/` prefix that npm tarballs use.
  Returns `{:ok, file_count}`.
  """
  @spec extract(binary(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def extract(tgz_data, dest_dir) do
    File.mkdir_p!(dest_dir)

    case :erl_tar.extract({:binary, tgz_data}, [:compressed, :memory]) do
      {:ok, entries} ->
        Enum.each(entries, &write_entry(&1, dest_dir))
        {:ok, length(entries)}

      {:error, reason} ->
        {:error, {:extract, reason}}
    end
  end

  defp write_entry({path, content}, dest_dir) do
    rel_path = strip_prefix(to_string(path))
    full_path = Path.join(dest_dir, rel_path)

    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp strip_prefix("package/" <> rest), do: rest
  defp strip_prefix(path), do: path
end
