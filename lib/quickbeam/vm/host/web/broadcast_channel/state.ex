defmodule QuickBEAM.VM.Host.Web.BroadcastChannel.State do
  @moduledoc "Process-local registry for BroadcastChannel listeners."

  @channels_key :qb_broadcast_channels

  def listeners(name), do: Map.get(channels(), name, [])

  def register(name, id, ref) do
    channels = channels()
    listeners = Map.get(channels, name, [])
    Process.put(@channels_key, Map.put(channels, name, [{id, ref} | listeners]))
  end

  def unregister(name, id) do
    channels = channels()
    listeners = Map.get(channels, name, [])
    updated_listeners = Enum.reject(listeners, fn {listener_id, _} -> listener_id == id end)
    Process.put(@channels_key, Map.put(channels, name, updated_listeners))
  end

  defp channels, do: Process.get(@channels_key, %{})
end
