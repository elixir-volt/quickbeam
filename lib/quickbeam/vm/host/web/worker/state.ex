defmodule QuickBEAM.VM.Host.Web.Worker.State do
  @moduledoc "Process-local worker registry and callback state."

  @workers_key :qb_beam_workers
  @sources_key :qb_worker_sources

  def init_callbacks(onmessage_ref, onerror_ref, listeners_ref) do
    Process.put(onmessage_ref, nil)
    Process.put(onerror_ref, nil)
    Process.put(listeners_ref, [])
  end

  def register_worker(worker_ref, worker_pid) do
    Process.put(@workers_key, Map.put(workers(), worker_ref, worker_pid))
  end

  def worker_pid(worker_ref), do: Map.get(workers(), worker_ref)

  def delete_worker(worker_ref) do
    Process.put(@workers_key, Map.delete(workers(), worker_ref))
  end

  def add_listener(listeners_ref, callback) do
    Process.put(listeners_ref, listeners(listeners_ref) ++ [callback])
  end

  def remove_listener(listeners_ref, callback) do
    Process.put(listeners_ref, Enum.reject(listeners(listeners_ref), &(&1 == callback)))
  end

  def listener_callback(onmessage_ref), do: Process.get(onmessage_ref, nil)
  def put_listener_callback(onmessage_ref, callback), do: Process.put(onmessage_ref, callback)

  def error_callback(onerror_ref), do: Process.get(onerror_ref, nil)
  def put_error_callback(onerror_ref, callback), do: Process.put(onerror_ref, callback)

  def listeners(listeners_ref), do: Process.get(listeners_ref, [])

  def register_source(worker_ref, onmessage_ref, listeners_ref) do
    Process.put(@sources_key, sources() ++ [{worker_ref, onmessage_ref, listeners_ref}])
  end

  def unregister_source(worker_ref) do
    Process.put(@sources_key, Enum.reject(sources(), fn {ref, _, _} -> ref == worker_ref end))
  end

  def sources, do: Process.get(@sources_key, [])

  defp workers, do: Process.get(@workers_key, %{})
end
