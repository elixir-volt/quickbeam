defmodule QuickBEAM.VM.Host.Web.Events do
  @moduledoc "EventTarget, Event, CustomEvent, and DOMException builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, constructor: 3, object: 1, object: 2]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Host.Web.EventListeners
  alias QuickBEAM.VM.Host.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{
      "EventTarget" => WebAPIs.register("EventTarget", &build_event_target/2),
      "Event" => WebAPIs.register("Event", &build_event/2),
      "CustomEvent" => WebAPIs.register("CustomEvent", &build_custom_event/2),
      "DOMException" => build_dom_exception_ctor()
    }
  end

  @doc "Builds an EventTarget object backed by VM heap state."
  def build_event_target(_args, _this) do
    listeners_ref = EventListeners.new()

    object do
      method "addEventListener" do
        [type, callback, opts] = argv(args, [nil, nil, nil])
        EventListeners.add(listeners_ref, type, callback, opts)
        :undefined
      end

      method "removeEventListener" do
        [type, callback, opts] = argv(args, [nil, nil, nil])
        EventListeners.remove(listeners_ref, type, callback, opts)
        :undefined
      end

      method "dispatchEvent" do
        event = arg(args, 0, nil)
        EventListeners.dispatch_event(listeners_ref, event)
      end
    end
  end

  @doc "Builds an Event object backed by VM heap state."
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
        if Get.get(this, "cancelable") == true do
          put_event_flag(this, "defaultPrevented", true)
        end

        :undefined
      end
    end
  end

  @doc "Builds a CustomEvent object backed by VM heap state."
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

  @doc "Builds a DOMException object backed by VM heap state."
  def build_dom_exception(args, _this) do
    message = args |> List.first("") |> to_string()
    name = args |> Enum.at(1, "Error") |> to_string()

    dom_exc_proto = get_dom_exception_proto()

    object extends: dom_exc_proto do
      prop("message", message)
      prop("name", name)
      prop("code", 0)
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

  @doc "Creates a DOMException value with the given name and message."
  def make_dom_exception(message, name) do
    build_dom_exception([message, name], nil)
  end
end
