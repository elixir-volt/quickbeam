defmodule QuickBEAM.BroadcastChannel do
  @moduledoc false

  @scope QuickBEAM.BroadcastChannel

  @spec join([String.t()], pid()) :: :ok
  def join([name], caller) do
    :pg.join(@scope, name, caller)
    :ok
  end

  @spec post(list(), pid()) :: :ok
  def post([name, message], caller) do
    for pid <- :pg.get_members(@scope, name), pid != caller do
      send(pid, {:broadcast_message, name, message})
    end

    :ok
  end

  @spec leave([String.t()], pid()) :: :ok
  def leave([name], caller) do
    :pg.leave(@scope, name, caller)
    :ok
  end
end
