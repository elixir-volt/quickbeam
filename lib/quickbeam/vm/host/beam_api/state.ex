defmodule QuickBEAM.VM.Host.BEAM.State do
  @moduledoc "Process-local state for the Beam host API."

  @on_message_key :qb_beam_on_message
  @monitors_key :qb_beam_monitors
  @pending_messages_key :qb_beam_pending_messages

  def put_handler(handler), do: Process.put(@on_message_key, handler)
  def handler, do: Process.get(@on_message_key)

  def take_pending_messages do
    pending = Process.get(@pending_messages_key, [])
    Process.delete(@pending_messages_key)
    pending
  end

  def append_pending_message(message) do
    pending = Process.get(@pending_messages_key, [])
    Process.put(@pending_messages_key, pending ++ [message])
  end

  def monitors, do: Process.get(@monitors_key, %{})
  def put_monitors(monitors), do: Process.put(@monitors_key, monitors)

  def put_monitor(ref, callback), do: put_monitors(Map.put(monitors(), ref, callback))
  def delete_monitor(ref), do: put_monitors(Map.delete(monitors(), ref))
end
