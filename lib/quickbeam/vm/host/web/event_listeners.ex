defmodule QuickBEAM.VM.Host.Web.EventListeners do
  @moduledoc "Shared listener storage and dispatch helpers for EventTarget-like Web APIs."

  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Host.Web.{Callback, StateRef}

  @doc "Creates a listener store reference."
  def new, do: StateRef.new(%{})

  @doc "Adds a listener entry for an event type."
  def add(listeners_ref, type, callback, opts \\ nil) do
    type = to_string(type)

    entry = %{
      "callback" => callback,
      "capture" => capture?(opts),
      "id" => make_ref(),
      "once" => once?(opts)
    }

    StateRef.update(listeners_ref, %{}, fn listeners ->
      entries = Map.get(listeners, type, [])

      if Enum.any?(entries, &same_listener?(&1, entry)) do
        listeners
      else
        Map.put(listeners, type, entries ++ [entry])
      end
    end)
  end

  @doc "Removes listener entries matching callback and capture for an event type."
  def remove(listeners_ref, type, callback, opts \\ nil) do
    type = to_string(type)
    capture? = capture?(opts)

    StateRef.update(listeners_ref, %{}, fn listeners ->
      listeners
      |> Map.get(type, [])
      |> Enum.reject(
        &(Map.get(&1, "callback") == callback and Map.get(&1, "capture") == capture?)
      )
      |> then(&Map.put(listeners, type, &1))
    end)
  end

  @doc "Dispatches an Event object and honors stopImmediatePropagation/defaultPrevented."
  def dispatch_event(listeners_ref, event) do
    type = event |> Get.get("type") |> to_string()
    dispatch(listeners_ref, type, [event], fn -> Get.get(event, "__stop_immediate__") == true end)
    Get.get(event, "defaultPrevented") != true
  end

  @doc "Dispatches callbacks for a plain event type."
  def dispatch_type(listeners_ref, type, args \\ []) do
    dispatch(listeners_ref, type, args, fn -> false end)
    :ok
  end

  defp dispatch(listeners_ref, type, args, stopped?) do
    type = to_string(type)
    snapshot = listeners_ref |> StateRef.get(%{}) |> Map.get(type, [])

    Enum.reduce_while(snapshot, false, fn entry, _stopped ->
      if listener_present?(listeners_ref, type, entry) do
        entry
        |> Map.get("callback")
        |> Callback.safe_invoke(args)

        if Map.get(entry, "once", false), do: remove_entry(listeners_ref, type, entry)

        if stopped?.(), do: {:halt, true}, else: {:cont, false}
      else
        {:cont, false}
      end
    end)
  end

  defp listener_present?(listeners_ref, type, entry) do
    listeners_ref
    |> StateRef.get(%{})
    |> Map.get(type, [])
    |> Enum.any?(&same_entry?(&1, entry))
  end

  defp remove_entry(listeners_ref, type, entry) do
    StateRef.update(listeners_ref, %{}, fn listeners ->
      listeners
      |> Map.get(type, [])
      |> Enum.reject(&same_entry?(&1, entry))
      |> then(&Map.put(listeners, type, &1))
    end)
  end

  defp same_listener?(left, right) do
    Map.get(left, "callback") == Map.get(right, "callback") and
      Map.get(left, "capture") == Map.get(right, "capture")
  end

  defp same_entry?(left, right), do: Map.get(left, "id") == Map.get(right, "id")

  defp once?({:obj, _} = opts), do: Get.get(opts, "once") == true
  defp once?(_), do: false

  defp capture?(true), do: true
  defp capture?({:obj, _} = opts), do: Get.get(opts, "capture") == true
  defp capture?(_), do: false
end
