defmodule QuickBEAM.VM.Runtime.Web.Events do
  @moduledoc "EventTarget, Event, CustomEvent, and DOMException builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, constructor: 3, object: 1]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.Web.{Callback, StateRef}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{
      "EventTarget" => WebAPIs.register("EventTarget", &build_event_target/2),
      "Event" => WebAPIs.register("Event", &build_event/2),
      "CustomEvent" => WebAPIs.register("CustomEvent", &build_custom_event/2),
      "DOMException" => build_dom_exception_ctor()
    }
  end

  def build_event_target(_args, _this) do
    listeners_ref = StateRef.new(%{})

    object do
      method "addEventListener" do
        [type, callback, opts] = argv(args, [nil, nil, nil])
        add_listener(listeners_ref, type, callback, opts)
        :undefined
      end

      method "removeEventListener" do
        [type, callback] = argv(args, [nil, nil])
        remove_listener(listeners_ref, type, callback)
        :undefined
      end

      method "dispatchEvent" do
        event = arg(args, 0, nil)
        dispatch_event(listeners_ref, event)
      end
    end
  end

  defp add_listener(listeners_ref, type, callback, opts) do
    type = to_string(type)
    entry = %{"callback" => callback, "once" => listener_once?(opts)}

    StateRef.update(listeners_ref, %{}, fn listeners ->
      Map.update(listeners, type, [entry], &(&1 ++ [entry]))
    end)
  end

  defp remove_listener(listeners_ref, type, callback) do
    type = to_string(type)

    StateRef.update(listeners_ref, %{}, fn listeners ->
      listeners
      |> Map.get(type, [])
      |> Enum.reject(&(Map.get(&1, "callback") == callback))
      |> then(&Map.put(listeners, type, &1))
    end)
  end

  defp dispatch_event(listeners_ref, event) do
    type = event |> Get.get("type") |> to_string()
    listeners = StateRef.get(listeners_ref, %{})
    type_listeners = Map.get(listeners, type, [])

    {survivors, _stopped?} =
      Enum.reduce(type_listeners, {[], false}, fn
        entry, {survivors, true} ->
          {[entry | survivors], true}

        entry, {survivors, false} ->
          callback = Map.get(entry, "callback")
          Callback.safe_invoke(callback, [event])

          keep? = not Map.get(entry, "once", false)
          survivors = if keep?, do: [entry | survivors], else: survivors
          stopped? = Get.get(event, "__stop_immediate__") == true
          {survivors, stopped?}
      end)

    StateRef.put(listeners_ref, Map.put(listeners, type, Enum.reverse(survivors)))
    Get.get(event, "defaultPrevented") != true
  end

  defp listener_once?({:obj, _} = opts), do: Get.get(opts, "once") == true
  defp listener_once?(_), do: false

  def build_event(args, _this) do
    type = args |> List.first("") |> to_string()
    opts = arg(args, 1, nil)

    {bubbles, cancelable} =
      case opts do
        {:obj, _} ->
          b = Get.get(opts, "bubbles") == true
          c = Get.get(opts, "cancelable") == true
          {b, c}

        _ ->
          {false, false}
      end

    object do
      prop("type", type)
      prop("bubbles", bubbles)
      prop("cancelable", cancelable)
      prop("defaultPrevented", false)
      prop("__stop_immediate__", false)

      method "stopPropagation" do
        :undefined
      end

      method "stopImmediatePropagation" do
        put_event_flag(this, "__stop_immediate__", true)
        :undefined
      end

      method "preventDefault" do
        put_event_flag(this, "defaultPrevented", true)
        :undefined
      end
    end
  end

  def build_custom_event(args, this) do
    event = build_event(args, this)

    detail =
      case arg(args, 1, nil) do
        {:obj, _} = opts -> Get.get(opts, "detail")
        _ -> nil
      end

    {:obj, ref} = event
    Heap.update_obj(ref, %{}, fn m -> Map.put(m, "detail", detail) end)
    event
  end

  def build_dom_exception(args, _this) do
    message = args |> List.first("") |> to_string()
    name = args |> Enum.at(1, "Error") |> to_string()

    dom_exc_proto = get_dom_exception_proto()

    object do
      prop("message", message)
      prop("name", name)
      prop("code", 0)
      prop("__proto__", dom_exc_proto)
    end
  end

  defp put_event_flag({:obj, ref}, key, value) do
    Heap.update_obj(ref, %{}, &Map.put(&1, key, value))
  end

  defp put_event_flag(_, _key, _value), do: :ok

  defp build_dom_exception_ctor do
    constructor "DOMException", &build_dom_exception/2 do
      proto do
        extends(build_error_proto())
      end
    end
  end

  defp get_dom_exception_proto, do: Runtime.global_class_proto("DOMException")
  defp build_error_proto, do: Runtime.global_class_proto("Error")

  def make_dom_exception(message, name) do
    build_dom_exception([message, name], nil)
  end
end
