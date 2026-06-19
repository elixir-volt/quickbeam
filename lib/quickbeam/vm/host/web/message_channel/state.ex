defmodule QuickBEAM.VM.Host.Web.MessageChannel.State do
  @moduledoc "Heap-backed state helpers for MessagePort queues."

  alias QuickBEAM.VM.Heap

  def new_queue do
    ref = make_ref()
    init_queue(ref)
    ref
  end

  def init_queue(ref) do
    Heap.put_obj(ref, %{messages: [], closed: false, started: false, handler: nil, listeners: []})
  end

  def get(ref), do: Heap.get_obj(ref, %{})
  def put(ref, state), do: Heap.put_obj(ref, state)

  def closed?(ref), do: Map.get(get(ref), :closed, false)
  def started?(state) when is_map(state), do: Map.get(state, :started, false)

  def start(ref), do: ref |> get() |> Map.put(:started, true) |> then(&put(ref, &1))
  def close(ref), do: ref |> get() |> Map.put(:closed, true) |> then(&put(ref, &1))

  def add_listener(ref, listener) do
    state = get(ref)
    put(ref, Map.put(state, :listeners, Map.get(state, :listeners, []) ++ [listener]))
  end

  def remove_listener(ref, callback) do
    state = get(ref)
    updated = Enum.reject(Map.get(state, :listeners, []), &(Map.get(&1, :callback) == callback))
    put(ref, Map.put(state, :listeners, updated))
  end

  def handler(ref), do: ref |> get() |> Map.get(:handler, nil)
  def error_handler(ref), do: ref |> get() |> Map.get(:error_handler, nil)

  def put_handler(ref, handler) do
    ref
    |> get()
    |> Map.merge(%{handler: handler, started: true})
    |> then(&put(ref, &1))
  end

  def put_error_handler(ref, handler) do
    ref
    |> get()
    |> Map.put(:error_handler, handler)
    |> then(&put(ref, &1))
  end

  def queue_message(ref, data) do
    state = get(ref)
    put(ref, Map.put(state, :messages, Map.get(state, :messages, []) ++ [data]))
  end

  def take_messages(ref) do
    state = get(ref)
    messages = Map.get(state, :messages, [])
    put(ref, Map.put(state, :messages, []))
    messages
  end

  def replace_listeners(ref, listeners) do
    ref
    |> get()
    |> Map.put(:listeners, listeners)
    |> then(&put(ref, &1))
  end
end
