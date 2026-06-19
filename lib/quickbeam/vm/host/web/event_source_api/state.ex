defmodule QuickBEAM.VM.Host.Web.EventSourceAPI.State do
  @moduledoc "Process-local registry for EventSource instances."

  @sources_key :qb_event_source_sources

  def sources, do: Process.get(@sources_key, [])

  def append_source(source) do
    Process.put(@sources_key, sources() ++ [source])
  end
end
