defmodule QuickBEAM.VM.Runtime.Web.EventSourceAPI do
  @moduledoc "EventSource constructor for BEAM mode — SSE client."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, argv: 2, object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Web.Callback
  alias QuickBEAM.VM.Runtime.WebAPIs

  # readyState values
  @connecting 0
  @open 1
  @closed 2

  @es_sources_key :qb_event_source_sources

  def bindings do
    %{"EventSource" => WebAPIs.register("EventSource", &build_event_source/2)}
  end

  @doc "Drain all pending EventSource messages. Called from drain_pending loop."
  def drain_all_event_sources do
    sources = Process.get(@es_sources_key, [])

    Enum.each(sources, fn {es_id, state_ref, onopen_ref, onmessage_ref, onerror_ref,
                           listeners_ref, last_event_id_ref} ->
      state = Heap.get_obj(state_ref, %{})

      unless Map.get(state, :readyState) == @closed do
        msgs = drain_sse_messages(es_id, [])

        Enum.each(msgs, fn msg ->
          case msg do
            {:eventsource_open, ^es_id} ->
              Heap.put_obj(state_ref, Map.put(state, :readyState, @open))
              handler = Heap.get_obj(onopen_ref, nil)
              event = Heap.wrap(%{"type" => "open"})
              fire_handler(handler, event)
              fire_listeners(listeners_ref, "open", event)

            {:eventsource_event, ^es_id, sse_event} ->
              event_type = Map.get(sse_event, :type, "message")
              data = Map.get(sse_event, :data, "")
              event_id = Map.get(sse_event, :id)

              if event_id, do: Heap.put_obj(last_event_id_ref, event_id)
              last_id = Heap.get_obj(last_event_id_ref, "")

              event =
                Heap.wrap(%{
                  "type" => event_type,
                  "data" => data,
                  "origin" => "",
                  "lastEventId" => last_id
                })

              if event_type == "message" do
                handler = Heap.get_obj(onmessage_ref, nil)
                fire_handler(handler, event)
              end

              fire_listeners(listeners_ref, event_type, event)

            {:eventsource_error, ^es_id, _reason} ->
              cur_state = Heap.get_obj(state_ref, %{})

              if Map.get(cur_state, :readyState) != @closed do
                handler = Heap.get_obj(onerror_ref, nil)
                event = Heap.wrap(%{"type" => "error"})
                fire_handler(handler, event)
                fire_listeners(listeners_ref, "error", event)
              end

            _ ->
              :ok
          end
        end)
      end
    end)
  end

  defp build_event_source([url | rest], _this) do
    url_str = to_string(url)
    _opts = Enum.at(rest, 0)

    parent_pid = self()
    es_id = make_ref()

    state_ref = make_ref()
    Heap.put_obj(state_ref, %{readyState: @connecting})

    onopen_ref = make_ref()
    onmessage_ref = make_ref()
    onerror_ref = make_ref()
    listeners_ref = make_ref()

    Heap.put_obj(onopen_ref, nil)
    Heap.put_obj(onmessage_ref, nil)
    Heap.put_obj(onerror_ref, nil)
    Heap.put_obj(listeners_ref, %{})

    last_event_id_ref = make_ref()
    Heap.put_obj(last_event_id_ref, "")

    task_pid = QuickBEAM.EventSource.open([url_str, es_id], parent_pid)

    Heap.put_obj(state_ref, %{readyState: @connecting, task_pid: task_pid})

    sources = Process.get(@es_sources_key, [])

    source =
      {es_id, state_ref, onopen_ref, onmessage_ref, onerror_ref, listeners_ref, last_event_id_ref}

    Process.put(@es_sources_key, sources ++ [source])

    schedule_sse_delivery(
      es_id,
      state_ref,
      onopen_ref,
      onmessage_ref,
      onerror_ref,
      listeners_ref,
      last_event_id_ref
    )

    object do
      prop("url", url_str)
      prop("withCredentials", false)
      prop("CONNECTING", @connecting)
      prop("OPEN", @open)
      prop("CLOSED", @closed)

      method "addEventListener" do
        [type, callback] = argv(args, ["message", nil])
        add_listener(listeners_ref, type, callback)
        :undefined
      end

      method "removeEventListener" do
        [type, callback] = argv(args, ["message", nil])
        remove_listener(listeners_ref, type, callback)
        :undefined
      end

      method "close" do
        state = Heap.get_obj(state_ref, %{})
        task_pid = Map.get(state, :task_pid)
        if task_pid, do: QuickBEAM.EventSource.close([task_pid])
        Heap.put_obj(state_ref, %{readyState: @closed})
        :undefined
      end

      method "dispatchEvent" do
        :undefined
      end

      accessor "readyState" do
        get do
          state_ref
          |> Heap.get_obj(%{})
          |> Map.get(:readyState, @connecting)
        end
      end

      accessor "lastEventId" do
        get do
          Heap.get_obj(last_event_id_ref, "")
        end
      end

      accessor "onopen" do
        get do
          Heap.get_obj(onopen_ref, nil)
        end

        set do
          Heap.put_obj(onopen_ref, arg(args, 0, nil))
          :undefined
        end
      end

      accessor "onmessage" do
        get do
          Heap.get_obj(onmessage_ref, nil)
        end

        set do
          Heap.put_obj(onmessage_ref, arg(args, 0, nil))
          :undefined
        end
      end

      accessor "onerror" do
        get do
          Heap.get_obj(onerror_ref, nil)
        end

        set do
          Heap.put_obj(onerror_ref, arg(args, 0, nil))
          :undefined
        end
      end
    end
  end

  defp build_event_source([], _this) do
    Heap.wrap(%{})
  end

  defp add_listener(listeners_ref, type, callback) do
    type = to_string(type)
    listeners = Heap.get_obj(listeners_ref, %{})
    callbacks = Map.get(listeners, type, [])
    Heap.put_obj(listeners_ref, Map.put(listeners, type, callbacks ++ [callback]))
  end

  defp remove_listener(listeners_ref, type, callback) do
    type = to_string(type)
    listeners = Heap.get_obj(listeners_ref, %{})

    callbacks =
      listeners
      |> Map.get(type, [])
      |> Enum.reject(&(&1 == callback))

    Heap.put_obj(listeners_ref, Map.put(listeners, type, callbacks))
  end

  defp schedule_sse_delivery(
         es_id,
         state_ref,
         onopen_ref,
         onmessage_ref,
         onerror_ref,
         listeners_ref,
         last_event_id_ref
       ) do
    Heap.enqueue_microtask(
      {:resolve, nil,
       {:builtin, "sse_poll",
        fn _, _ ->
          poll_sse_messages(
            es_id,
            state_ref,
            onopen_ref,
            onmessage_ref,
            onerror_ref,
            listeners_ref,
            last_event_id_ref,
            100
          )

          :undefined
        end}, :undefined}
    )
  end

  defp poll_sse_messages(
         es_id,
         state_ref,
         onopen_ref,
         onmessage_ref,
         onerror_ref,
         listeners_ref,
         last_event_id_ref,
         max_polls
       ) do
    state = Heap.get_obj(state_ref, %{})

    if Map.get(state, :readyState) == @closed or max_polls <= 0 do
      :done
    else
      msgs = drain_sse_messages(es_id, [])

      Enum.each(msgs, fn msg ->
        case msg do
          {:eventsource_open, ^es_id} ->
            Heap.put_obj(state_ref, Map.put(state, :readyState, @open))
            handler = Heap.get_obj(onopen_ref, nil)
            event = Heap.wrap(%{"type" => "open"})
            fire_handler(handler, event)
            fire_listeners(listeners_ref, "open", event)

          {:eventsource_event, ^es_id, sse_event} ->
            event_type = Map.get(sse_event, :type, "message")
            data = Map.get(sse_event, :data, "")
            event_id = Map.get(sse_event, :id)

            if event_id, do: Heap.put_obj(last_event_id_ref, event_id)
            last_id = Heap.get_obj(last_event_id_ref, "")

            event =
              Heap.wrap(%{
                "type" => event_type,
                "data" => data,
                "origin" => "",
                "lastEventId" => last_id
              })

            if event_type == "message" do
              handler = Heap.get_obj(onmessage_ref, nil)
              fire_handler(handler, event)
            end

            fire_listeners(listeners_ref, event_type, event)

          {:eventsource_error, ^es_id, _reason} ->
            new_state = Map.get(state, :readyState, @connecting)

            if new_state != @closed do
              handler = Heap.get_obj(onerror_ref, nil)
              event = Heap.wrap(%{"type" => "error"})
              fire_handler(handler, event)
              fire_listeners(listeners_ref, "error", event)
            end

          _ ->
            :ok
        end
      end)

      if msgs != [] do
        poll_sse_messages(
          es_id,
          state_ref,
          onopen_ref,
          onmessage_ref,
          onerror_ref,
          listeners_ref,
          last_event_id_ref,
          max_polls - 1
        )
      end
    end
  end

  defp drain_sse_messages(es_id, acc) do
    receive do
      {:eventsource_open, ^es_id} = msg -> drain_sse_messages(es_id, acc ++ [msg])
      {:eventsource_event, ^es_id, _} = msg -> drain_sse_messages(es_id, acc ++ [msg])
      {:eventsource_error, ^es_id, _} = msg -> drain_sse_messages(es_id, acc ++ [msg])
    after
      0 -> acc
    end
  end

  defp fire_handler(handler, event) when handler not in [nil, :undefined] do
    Callback.safe_invoke(handler, [event])
  end

  defp fire_handler(_handler, _event), do: :ok

  defp fire_listeners(listeners_ref, type, event) do
    listeners_ref
    |> Heap.get_obj(%{})
    |> Map.get(type, [])
    |> Enum.each(&Callback.safe_invoke(&1, [event]))
  end
end
