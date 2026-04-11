defmodule QuickBEAM.NodeOS do
  @moduledoc false

  @spec platform([]) :: String.t()
  def platform([]) do
    QuickBEAM.NodeProcess.platform([])
  end

  @spec arch([]) :: String.t()
  def arch([]) do
    QuickBEAM.NodeProcess.arch([])
  end

  @spec hostname([]) :: String.t()
  def hostname([]) do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  @spec release([]) :: String.t()
  def release([]) do
    :erlang.system_info(:system_version)
    |> List.to_string()
    |> String.trim()
  end

  @spec homedir([]) :: String.t()
  def homedir([]) do
    System.user_home() || "/tmp"
  end

  @spec tmpdir([]) :: String.t()
  def tmpdir([]) do
    System.tmp_dir() || "/tmp"
  end

  @spec cpu_count([]) :: pos_integer()
  def cpu_count([]) do
    System.schedulers_online()
  end

  @spec totalmem([]) :: non_neg_integer()
  def totalmem([]) do
    :erlang.memory(:total)
  end

  @spec freemem([]) :: integer()
  def freemem([]) do
    :erlang.memory(:total) - :erlang.memory(:processes_used) - :erlang.memory(:system)
  end

  @spec uptime([]) :: non_neg_integer()
  def uptime([]) do
    :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
  end
end
