defmodule QuickBEAM.NodeProcess do
  @moduledoc false

  def env_get([key]) when is_binary(key) do
    System.get_env(key)
  end

  def env_set([key, value]) when is_binary(key) and is_binary(value) do
    System.put_env(key, value)
    true
  end

  def env_delete([key]) when is_binary(key) do
    System.delete_env(key)
    true
  end

  def env_keys([]) do
    System.get_env() |> Map.keys()
  end

  def platform([]) do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:unix, :freebsd} -> "freebsd"
      {:win32, _} -> "win32"
      {_, os} -> Atom.to_string(os)
    end
  end

  def arch([]) do
    :erlang.system_info(:system_architecture)
    |> List.to_string()
    |> parse_arch()
  end

  def pid([]) do
    :os.getpid() |> List.to_integer()
  end

  def cwd([]) do
    File.cwd!()
  end

  def console_write([level, message]) do
    case level do
      "error" -> :logger.error(message)
      _ -> :logger.info(message)
    end

    true
  end

  defp parse_arch(arch) do
    cond do
      String.contains?(arch, "aarch64") -> "arm64"
      String.contains?(arch, "arm") -> "arm"
      String.contains?(arch, "x86_64") -> "x64"
      String.contains?(arch, "i686") -> "ia32"
      true -> arch
    end
  end
end
