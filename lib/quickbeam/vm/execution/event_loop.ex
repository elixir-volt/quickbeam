defmodule QuickBEAM.VM.Execution.EventLoop do
  @moduledoc "Coordinates host event sources that can settle VM jobs while awaiting promises."

  alias QuickBEAM.VM.Host.Web.EventSourceAPI
  alias QuickBEAM.VM.Host.Web.Timers
  alias QuickBEAM.VM.Host.Web.Worker

  def drain_host_tasks do
    did_fire = Timers.drain_timers()
    Worker.drain_all_worker_messages()
    EventSourceAPI.drain_all_event_sources()
    did_fire
  end

  def next_delay_ms, do: Timers.next_timer_delay_ms()
end
