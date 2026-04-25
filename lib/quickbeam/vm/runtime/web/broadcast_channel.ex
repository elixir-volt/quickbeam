defmodule QuickBEAM.VM.Runtime.Web.BroadcastChannel do
  @moduledoc "BroadcastChannel builtin for BEAM mode — in-process pub/sub via process dictionary."

  import QuickBEAM.VM.Builtin, only: [build_methods: 1]

  alias QuickBEAM.VM.{Heap, Invocation}
  alias QuickBEAM.VM.Runtime.WebAPIs

  @channels_key :qb_broadcast_channels

  def bindings do
    %{"BroadcastChannel" => WebAPIs.register("BroadcastChannel", &build_channel/2)}
  end

  defp build_channel(args, _this) do
    channel_name = args |> List.first("") |> to_string()
    listener_ref = make_ref()
    Heap.put_obj(listener_ref, nil)

    channel_id = make_ref()
    register_channel(channel_name, channel_id, listener_ref)

    Heap.wrap(
      build_methods do
        val("name", channel_name)

        method "postMessage" do
          data = List.first(args, :undefined)

          channel_name
          |> get_channel_listeners()
          |> Enum.each(fn {id, lref} ->
            if id != channel_id do
              handler = Process.get(lref)

              if handler != nil and handler != false do
                event = Heap.wrap(%{"data" => data, "type" => "message"})

                try do
                  Invocation.invoke_with_receiver(handler, [event], :undefined)
                rescue
                  _ -> :ok
                catch
                  _, _ -> :ok
                end
              end
            end
          end)

          :undefined
        end

        method "close" do
          unregister_channel(channel_name, channel_id)
          :undefined
        end
      end
      |> Map.merge(%{
        "onmessage" =>
          {:accessor,
           {:builtin, "get onmessage", fn _, _ -> Heap.get_obj(listener_ref, nil) end},
           {:builtin, "set onmessage",
            fn args, _ ->
              handler = List.first(args, nil)
              Heap.put_obj(listener_ref, handler)
              :undefined
            end}}
      })
    )
  end

  defp register_channel(name, id, ref) do
    channels = Process.get(@channels_key, %{})
    listeners = Map.get(channels, name, [])
    updated = Map.put(channels, name, [{id, ref} | listeners])
    Process.put(@channels_key, updated)
  end

  defp unregister_channel(name, id) do
    channels = Process.get(@channels_key, %{})
    listeners = Map.get(channels, name, [])
    updated_listeners = Enum.reject(listeners, fn {lid, _} -> lid == id end)
    updated = Map.put(channels, name, updated_listeners)
    Process.put(@channels_key, updated)
  end

  defp get_channel_listeners(name) do
    channels = Process.get(@channels_key, %{})
    Map.get(channels, name, [])
  end
end
