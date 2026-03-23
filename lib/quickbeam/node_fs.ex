defmodule QuickBEAM.NodeFS do
  @moduledoc false

  def read_file([path]) when is_binary(path) do
    case File.read(path) do
      {:ok, data} -> {:bytes, data}
      {:error, _} -> nil
    end
  end

  def write_file([path, data]) when is_binary(path) do
    case File.write(path, data) do
      :ok -> true
      {:error, _} -> false
    end
  end

  def append_file([path, data]) when is_binary(path) do
    case File.write(path, data, [:append]) do
      :ok -> true
      {:error, _} -> false
    end
  end

  def exists([path]) when is_binary(path) do
    File.exists?(path)
  end

  def mkdir([path, recursive]) when is_binary(path) do
    result = if recursive, do: File.mkdir_p(path), else: File.mkdir(path)

    case result do
      :ok -> true
      {:error, :eexist} -> true
      {:error, _} -> false
    end
  end

  def readdir([path]) when is_binary(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> nil
    end
  end

  def stat([path]) when is_binary(path) do
    file_stat(path, false)
  end

  def lstat([path]) when is_binary(path) do
    file_stat(path, true)
  end

  def unlink([path]) when is_binary(path) do
    case File.rm(path) do
      :ok -> true
      {:error, _} -> false
    end
  end

  def rename([old_path, new_path]) when is_binary(old_path) and is_binary(new_path) do
    case File.rename(old_path, new_path) do
      :ok -> true
      {:error, _} -> false
    end
  end

  def rm([path, recursive, force]) when is_binary(path) do
    result = if recursive, do: File.rm_rf(path), else: File.rm(path)

    case result do
      :ok -> true
      {:ok, _} -> true
      {:error, _, _} -> force
      {:error, :enoent} -> force
      {:error, _} -> false
    end
  end

  def copy_file([src, dest]) when is_binary(src) and is_binary(dest) do
    case File.cp(src, dest) do
      :ok -> true
      {:error, _} -> false
    end
  end

  def realpath([path]) when is_binary(path) do
    expanded = Path.expand(path)

    case :file.read_link_info(String.to_charlist(path)) do
      {:ok, _} -> if File.exists?(expanded), do: expanded, else: nil
      _ -> nil
    end
  end

  defp file_stat(path, follow_links) do
    stat_fn = if follow_links, do: &File.lstat/1, else: &File.stat/1

    case stat_fn.(path) do
      {:ok, %File.Stat{} = s} ->
        epoch = fn
          nil -> 0
          dt -> DateTime.to_unix(dt, :millisecond)
        end

        %{
          "size" => s.size,
          "mode" => s.mode,
          "type" => Atom.to_string(s.type),
          "mtime" => epoch.(datetime_from_erl(s.mtime)),
          "atime" => epoch.(datetime_from_erl(s.atime)),
          "ctime" => epoch.(datetime_from_erl(s.ctime)),
          "birthtime" => epoch.(datetime_from_erl(s.ctime))
        }

      {:error, _} ->
        nil
    end
  end

  defp datetime_from_erl({{y, m, d}, {h, min, s}}) do
    case NaiveDateTime.new(y, m, d, h, min, s) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp datetime_from_erl(_), do: nil
end
