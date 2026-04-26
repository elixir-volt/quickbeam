defmodule QuickBEAM.VM.Runtime.Web.MessageChannel do
  @moduledoc "MessageChannel and MessagePort builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, object: 1, object: 2]

  alias QuickBEAM.VM.{Heap, Runtime}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.StructuredClone
  alias QuickBEAM.VM.Runtime.Web.Callback
  alias QuickBEAM.VM.Runtime.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    port_ctor = WebAPIs.register("MessagePort", &build_port_stub/2)

    channel_ctor =
      WebAPIs.register("MessageChannel", fn _args, _this -> build_channel(port_ctor) end)

    %{
      "MessageChannel" => channel_ctor,
      "MessagePort" => port_ctor,
      "MessageEvent" => build_message_event_ctor()
    }
  end

  defp build_port_stub(_args, _this), do: build_port_pair_port(make_ref(), make_ref())

  defp build_channel(port_ctor) do
    q1 = make_ref()
    q2 = make_ref()

    Heap.put_obj(q1, %{messages: [], closed: false, started: false, handler: nil, listeners: []})
    Heap.put_obj(q2, %{messages: [], closed: false, started: false, handler: nil, listeners: []})

    port1 = build_port(q1, q2, port_ctor)
    port2 = build_port(q2, q1, port_ctor)

    Heap.wrap(%{"port1" => port1, "port2" => port2})
  end

  defp build_port_pair_port(my_q, peer_q) do
    Heap.put_obj(my_q, %{messages: [], closed: false, started: false, handler: nil, listeners: []})

    Heap.put_obj(peer_q, %{
      messages: [],
      closed: false,
      started: false,
      handler: nil,
      listeners: []
    })

    build_port(my_q, peer_q, Runtime.global_constructor("MessagePort"))
  end

  defp build_port(my_q, peer_q, port_ctor) do
    port_proto = Runtime.global_class_proto("MessagePort")

    object heap: false do
      prop("constructor", port_ctor)

      method "postMessage" do
        data = arg(args, 0, :undefined)
        state = Heap.get_obj(my_q, %{})

        unless Map.get(state, :closed, false) do
          peer_state = Heap.get_obj(peer_q, %{})

          unless Map.get(peer_state, :closed, false) do
            data |> StructuredClone.clone() |> then(&deliver_or_queue(peer_q, &1))
          end
        end

        :undefined
      end

      method "start" do
        state = Heap.get_obj(my_q, %{})
        Heap.put_obj(my_q, %{state | started: true})
        drain_queue(my_q)
        :undefined
      end

      method "close" do
        state = Heap.get_obj(my_q, %{})
        Heap.put_obj(my_q, %{state | closed: true})
        :undefined
      end

      method "addEventListener" do
        [type, callback, opts] = argv(args, [nil, nil, nil])

        if to_string(type) == "message" do
          state = Heap.get_obj(my_q, %{})
          listeners = Map.get(state, :listeners, [])
          listener = %{callback: callback, once: listener_once?(opts)}
          Heap.put_obj(my_q, Map.put(state, :listeners, listeners ++ [listener]))
        end

        :undefined
      end

      method "removeEventListener" do
        [type, callback] = argv(args, [nil, nil])

        if to_string(type) == "message" do
          state = Heap.get_obj(my_q, %{})
          listeners = Map.get(state, :listeners, [])
          updated = Enum.reject(listeners, &(Map.get(&1, :callback) == callback))
          Heap.put_obj(my_q, Map.put(state, :listeners, updated))
        end

        :undefined
      end

      method "dispatchEvent" do
        :undefined
      end

      accessor "onmessage" do
        get do
          my_q |> Heap.get_obj(%{}) |> Map.get(:handler, nil)
        end

        set do
          state = Heap.get_obj(my_q, %{})
          Heap.put_obj(my_q, %{state | handler: arg(args, 0, nil), started: true})
          drain_queue(my_q)
          :undefined
        end
      end

      accessor "onmessageerror" do
        get do
          my_q |> Heap.get_obj(%{}) |> Map.get(:error_handler, nil)
        end

        set do
          state = Heap.get_obj(my_q, %{})
          Heap.put_obj(my_q, Map.put(state, :error_handler, arg(args, 0, nil)))
          :undefined
        end
      end
    end
    |> QuickBEAM.VM.Builtin.put_if_present("__proto__", port_proto)
    |> Heap.wrap()
  end

  defp listener_once?({:obj, _} = opts), do: Get.get(opts, "once") == true
  defp listener_once?(_), do: false

  defp deliver_or_queue(q_ref, data) do
    state = Heap.get_obj(q_ref, %{})
    event = make_message_event(data)

    if Map.get(state, :started, false) do
      handler = Map.get(state, :handler)
      listeners = Map.get(state, :listeners, [])

      dispatch_event(event, handler, listeners, q_ref)
    else
      messages = Map.get(state, :messages, [])
      Heap.put_obj(q_ref, Map.put(state, :messages, messages ++ [data]))
    end
  end

  defp drain_queue(q_ref) do
    state = Heap.get_obj(q_ref, %{})
    messages = Map.get(state, :messages, [])

    if messages != [] and Map.get(state, :started, false) do
      handler = Map.get(state, :handler)
      listeners = Map.get(state, :listeners, [])
      Heap.put_obj(q_ref, Map.put(state, :messages, []))

      Enum.each(messages, fn data ->
        event = make_message_event(data)
        dispatch_event(event, handler, listeners, q_ref)
      end)
    end
  end

  defp dispatch_event(event, handler, _listeners, q_ref) do
    Heap.enqueue_microtask(
      {:resolve, nil,
       {:builtin, "deliver",
        fn _, _ ->
          if handler != nil and handler != :undefined do
            Callback.safe_invoke(handler, [event])
          end

          state = Heap.get_obj(q_ref, %{})
          all_listeners = Map.get(state, :listeners, [])

          survivors =
            Enum.reject(all_listeners, fn entry ->
              entry
              |> Map.get(:callback)
              |> Callback.safe_invoke([event])

              Map.get(entry, :once, false)
            end)

          Heap.put_obj(q_ref, Map.put(state, :listeners, survivors))
          :undefined
        end}, :undefined}
    )
  end

  defp make_message_event(data) do
    base = %{
      "type" => "message",
      "data" => data,
      "origin" => "",
      "lastEventId" => "",
      "source" => nil,
      "ports" => []
    }

    me_ctor = Runtime.global_constructor("MessageEvent")

    base =
      if me_ctor do
        base
        |> Map.put("constructor", me_ctor)
        |> QuickBEAM.VM.Builtin.put_if_present(
          "__proto__",
          Runtime.global_class_proto("MessageEvent")
        )
      else
        base
      end

    Heap.wrap(base)
  end

  defp build_message_event_ctor do
    WebAPIs.register("MessageEvent", fn args, _this ->
      [type, opts] = argv(args, ["message", nil])

      data =
        case opts do
          {:obj, _} -> Get.get(opts, "data")
          _ -> :undefined
        end

      object do
        prop("type", to_string(type))
        prop("data", data)
        prop("origin", "")
        prop("lastEventId", "")
        prop("source", nil)
        prop("ports", [])
      end
    end)
  end
end
