defmodule QuickBEAM.NodeOS do
  @moduledoc false

  def platform([]) do
    QuickBEAM.NodeProcess.platform([])
  end

  def arch([]) do
    QuickBEAM.NodeProcess.arch([])
  end

  def hostname([]) do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  def release([]) do
    :erlang.system_info(:system_version)
    |> List.to_string()
    |> String.trim()
  end

  def homedir([]) do
    System.user_home() || "/tmp"
  end

  def tmpdir([]) do
    System.tmp_dir() || "/tmp"
  end

  def cpu_count([]) do
    System.schedulers_online()
  end

  def totalmem([]) do
    :erlang.memory(:total)
  end

  def freemem([]) do
    :erlang.memory(:total) - :erlang.memory(:processes_used) - :erlang.memory(:system)
  end

  def uptime([]) do
    :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
  end
end
