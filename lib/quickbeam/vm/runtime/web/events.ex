defmodule QuickBEAM.VM.Runtime.Web.Events do
  @moduledoc "EventTarget, Event, CustomEvent, and DOMException builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    %{
      "EventTarget" => WebAPIs.register("EventTarget", &build_event_target/2),
      "Event" => WebAPIs.register("Event", &build_event/2),
      "CustomEvent" => WebAPIs.register("CustomEvent", &build_custom_event/2),
      "DOMException" => build_dom_exception_ctor()
    }
  end

  def build_event_target(_args, _this) do
    listeners_ref = make_ref()
    Heap.put_obj(listeners_ref, %{})

    Heap.wrap(
      build_methods do
        method "addEventListener" do
          [type, callback | rest] = args ++ [nil, nil, nil]
          opts = List.first(rest)
          t = to_string(type)

          once =
            case opts do
              {:obj, _} -> Get.get(opts, "once") == true
              true -> false
              _ -> false
            end

          listener_entry = %{"callback" => callback, "once" => once}
          listeners = Heap.get_obj(listeners_ref, %{})
          existing = Map.get(listeners, t, [])
          updated = Map.put(listeners, t, existing ++ [listener_entry])
          Heap.put_obj(listeners_ref, updated)
          :undefined
        end

        method "removeEventListener" do
          [type, callback | _] = args ++ [nil, nil]
          t = to_string(type)
          listeners = Heap.get_obj(listeners_ref, %{})
          existing = Map.get(listeners, t, [])

          updated_list =
            Enum.reject(existing, fn entry ->
              Map.get(entry, "callback") == callback
            end)

          Heap.put_obj(listeners_ref, Map.put(listeners, t, updated_list))
          :undefined
        end

        method "dispatchEvent" do
          event = List.first(args)
          type = event |> Get.get("type") |> to_string()
          listeners = Heap.get_obj(listeners_ref, %{})
          type_listeners = Map.get(listeners, type, [])

          stop_ref = make_ref()
          Process.put(stop_ref, false)

          survivors =
            Enum.reject(type_listeners, fn entry ->
              if Process.get(stop_ref) do
                false
              else
                cb = Map.get(entry, "callback")
                once = Map.get(entry, "once", false)

                try do
                  Invocation.invoke_with_receiver(cb, [event], :undefined)
                rescue
                  _ -> :ok
                catch
                  _, _ -> :ok
                end

                if Get.get(event, "__stop_immediate__") == true do
                  Process.put(stop_ref, true)
                end

                once
              end
            end)

          updated = Map.put(listeners, type, survivors)
          Heap.put_obj(listeners_ref, updated)
          not (Get.get(event, "defaultPrevented") == true)
        end
      end
    )
  end

  def build_event(args, _this) do
    type = args |> List.first("") |> to_string()
    opts = Enum.at(args, 1)

    {bubbles, cancelable} =
      case opts do
        {:obj, _} ->
          b = Get.get(opts, "bubbles") == true
          c = Get.get(opts, "cancelable") == true
          {b, c}

        _ ->
          {false, false}
      end

    stop_ref = make_ref()
    Heap.put_obj(stop_ref, false)

    Heap.wrap(
      build_methods do
        val("type", type)
        val("bubbles", bubbles)
        val("cancelable", cancelable)
        val("defaultPrevented", false)
        val("__stop_immediate__", false)

        method "stopPropagation" do
          :undefined
        end

        method "stopImmediatePropagation" do
          Heap.update_obj(elem(this, 1), %{}, fn m ->
            Map.put(m, "__stop_immediate__", true)
          end)

          :undefined
        end

        method "preventDefault" do
          Heap.update_obj(elem(this, 1), %{}, fn m ->
            Map.put(m, "defaultPrevented", true)
          end)

          :undefined
        end
      end
    )
  end

  def build_custom_event(args, this) do
    event = build_event(args, this)
    detail = case Enum.at(args, 1) do
      {:obj, _} = opts -> Get.get(opts, "detail")
      _ -> nil
    end

    case event do
      {:obj, ref} ->
        Heap.update_obj(ref, %{}, fn m -> Map.put(m, "detail", detail) end)
        event

      _ ->
        event
    end
  end

  def build_dom_exception(args, _this) do
    message = args |> List.first("") |> to_string()
    name = args |> Enum.at(1, "Error") |> to_string()

    dom_exc_proto = get_dom_exception_proto()

    Heap.wrap(%{
      "message" => message,
      "name" => name,
      "code" => 0,
      "__proto__" => dom_exc_proto
    })
  end

  defp build_dom_exception_ctor do
    ctor = {:builtin, "DOMException", &build_dom_exception/2}
    proto = Heap.wrap(%{"constructor" => ctor, "__proto__" => build_error_proto()})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end

  defp get_dom_exception_proto do
    case Heap.get_global_cache() do
      nil -> nil
      globals ->
        case Map.get(globals, "DOMException") do
          {:builtin, _, _} = ctor -> Heap.get_class_proto(ctor)
          _ -> nil
        end
    end
  end

  defp build_error_proto do
    case Heap.get_global_cache() do
      nil ->
        nil

      globals ->
        case Map.get(globals, "Error") do
          {:builtin, _, _} = ctor -> Heap.get_class_proto(ctor)
          _ -> nil
        end
    end
  end

  def make_dom_exception(message, name) do
    build_dom_exception([message, name], nil)
  end
end
