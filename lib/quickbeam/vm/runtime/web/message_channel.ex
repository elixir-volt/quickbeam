defmodule QuickBEAM.VM.Runtime.Web.MessageChannel do
  @moduledoc "MessageChannel and MessagePort builtins for BEAM mode."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.StructuredClone
  alias QuickBEAM.VM.Runtime.WebAPIs

  def bindings do
    port_ctor = WebAPIs.register("MessagePort", &build_port_stub/2)
    channel_ctor = WebAPIs.register("MessageChannel", fn _args, _this -> build_channel(port_ctor) end)

    %{
      "MessageChannel" => channel_ctor,
      "MessagePort" => port_ctor,
      "MessageEvent" => build_message_event_ctor()
    }
  end

  defp build_port_stub(_args, _this), do: build_port_pair_port(make_ref(), make_ref())

  defp build_channel(port_ctor) do
    q1 = make_ref()  # queue for port1→port2
    q2 = make_ref()  # queue for port2→port1

    Heap.put_obj(q1, %{messages: [], closed: false, started: false, handler: nil, listeners: []})
    Heap.put_obj(q2, %{messages: [], closed: false, started: false, handler: nil, listeners: []})

    port1 = build_port(q1, q2, port_ctor)
    port2 = build_port(q2, q1, port_ctor)

    Heap.wrap(%{"port1" => port1, "port2" => port2})
  end

  defp build_port_pair_port(my_q, peer_q) do
    # Used for stub — create minimal port
    Heap.put_obj(my_q, %{messages: [], closed: false, started: false, handler: nil, listeners: []})
    Heap.put_obj(peer_q, %{messages: [], closed: false, started: false, handler: nil, listeners: []})

    # Get MessagePort ctor for instanceof check
    port_ctor = case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "MessagePort")
    end

    build_port(my_q, peer_q, port_ctor)
  end

  defp build_port(my_q, peer_q, port_ctor) do
    port_proto = if port_ctor, do: Heap.get_class_proto(port_ctor), else: nil

    # Accessor for onmessage that starts the port
    onmessage_accessor = {:accessor,
      {:builtin, "get onmessage",
       fn _, _ ->
         state = Heap.get_obj(my_q, %{})
         Map.get(state, :handler, nil)
       end},
      {:builtin, "set onmessage",
       fn [handler | _], _ ->
         state = Heap.get_obj(my_q, %{})
         # Setting onmessage auto-starts the port
         new_state = %{state | handler: handler, started: true}
         Heap.put_obj(my_q, new_state)
         # Drain any queued messages
         drain_queue(my_q)
         :undefined
       end}}

    onmessageerror_accessor = {:accessor,
      {:builtin, "get onmessageerror",
       fn _, _ ->
         state = Heap.get_obj(my_q, %{})
         Map.get(state, :error_handler, nil)
       end},
      {:builtin, "set onmessageerror", fn [h | _], _ ->
         state = Heap.get_obj(my_q, %{})
         Heap.put_obj(my_q, Map.put(state, :error_handler, h))
         :undefined
       end}}

    methods = build_methods do
      method "postMessage" do
        [data | _] = args ++ [:undefined]
        state = Heap.get_obj(my_q, %{})

        unless Map.get(state, :closed, false) do
          # Deliver to the peer queue
          peer_state = Heap.get_obj(peer_q, %{})
          unless Map.get(peer_state, :closed, false) do
            cloned = StructuredClone.clone(data)
            deliver_or_queue(peer_q, cloned)
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
        [type, callback | rest] = args ++ [nil, nil, nil]
        t = to_string(type)

        once = case Enum.at(rest, 0) do
          {:obj, _} = opts -> Get.get(opts, "once") == true
          true -> false
          _ -> false
        end

        if t == "message" do
          state = Heap.get_obj(my_q, %{})
          listeners = Map.get(state, :listeners, [])
          new_listeners = listeners ++ [%{callback: callback, once: once}]
          Heap.put_obj(my_q, Map.put(state, :listeners, new_listeners))
        end

        :undefined
      end

      method "removeEventListener" do
        [type, callback | _] = args ++ [nil, nil]
        t = to_string(type)

        if t == "message" do
          state = Heap.get_obj(my_q, %{})
          listeners = Map.get(state, :listeners, [])
          updated = Enum.reject(listeners, fn e -> Map.get(e, :callback) == callback end)
          Heap.put_obj(my_q, Map.put(state, :listeners, updated))
        end

        :undefined
      end

      method "dispatchEvent" do
        :undefined
      end
    end

    map = Map.merge(methods, %{
      "onmessage" => onmessage_accessor,
      "onmessageerror" => onmessageerror_accessor
    })

    map = if port_proto, do: Map.put(map, "__proto__", port_proto), else: map

    Heap.wrap(map)
  end

  defp deliver_or_queue(q_ref, data) do
    state = Heap.get_obj(q_ref, %{})
    event = make_message_event(data)

    if Map.get(state, :started, false) do
      # Port is started — deliver immediately via microtask
      handler = Map.get(state, :handler)
      listeners = Map.get(state, :listeners, [])

      dispatch_event(event, handler, listeners, q_ref)
    else
      # Queue the message
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
    # Schedule via microtask to ensure async delivery
    Heap.enqueue_microtask({:resolve, nil,
      {:builtin, "deliver",
       fn _, _ ->
         if handler != nil and handler != :undefined do
           try do
             Invocation.invoke_with_receiver(handler, [event], :undefined)
           rescue
             _ -> :ok
           catch
             _, _ -> :ok
           end
         end

         state = Heap.get_obj(q_ref, %{})
         all_listeners = Map.get(state, :listeners, [])

         survivors = Enum.reject(all_listeners, fn entry ->
           cb = Map.get(entry, :callback)
           once = Map.get(entry, :once, false)

           try do
             Invocation.invoke_with_receiver(cb, [event], :undefined)
           rescue
             _ -> :ok
           catch
             _, _ -> :ok
           end

           once
         end)

         Heap.put_obj(q_ref, Map.put(state, :listeners, survivors))
         :undefined
       end},
      :undefined})
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

    # Add constructor and proto for instanceof MessageEvent
    me_ctor = case Heap.get_global_cache() do
      nil -> nil
      globals -> Map.get(globals, "MessageEvent")
    end

    base = if me_ctor do
      proto = Heap.get_class_proto(me_ctor)
      base
      |> Map.put("constructor", me_ctor)
      |> then(fn m -> if proto, do: Map.put(m, "__proto__", proto), else: m end)
    else
      base
    end

    Heap.wrap(base)
  end

  defp build_message_event_ctor do
    WebAPIs.register("MessageEvent", fn args, _this ->
      [type | rest] = args ++ ["message"]
      opts = Enum.at(rest, 0)

      data = case opts do
        {:obj, _} -> Get.get(opts, "data")
        _ -> :undefined
      end

      Heap.wrap(%{
        "type" => to_string(type),
        "data" => data,
        "origin" => "",
        "lastEventId" => "",
        "source" => nil,
        "ports" => []
      })
    end)
  end
end
