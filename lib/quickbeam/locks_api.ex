defmodule QuickBEAM.LocksAPI do
  @moduledoc false

  @spec request_lock(list(), pid()) :: String.t()
  def request_lock([name, mode, if_available], caller_pid) do
    case QuickBEAM.LockManager.request_lock(name, mode, caller_pid, if_available) do
      :granted -> "granted"
      :not_available -> "not_available"
      :holder_down -> "holder_down"
    end
  end

  @spec release_lock([String.t()], pid()) :: nil
  def release_lock([name], caller_pid) do
    QuickBEAM.LockManager.release_lock(name, caller_pid)
    nil
  end

  @spec query_locks(term()) :: map()
  def query_locks(_args) do
    QuickBEAM.LockManager.query()
  end
end
