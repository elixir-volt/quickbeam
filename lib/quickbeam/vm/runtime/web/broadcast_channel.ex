defmodule QuickBEAM.VM.Runtime.Web.BroadcastChannel do
  @moduledoc "BroadcastChannel builtin for BEAM mode — in-process pub/sub via process dictionary."

  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Web.Callback
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

    object do
      prop("name", channel_name)

      method "postMessage" do
        data = arg(args, 0, :undefined)
        deliver_message(channel_name, channel_id, data)
        :undefined
      end

      method "close" do
        unregister_channel(channel_name, channel_id)
        :undefined
      end

      accessor "onmessage" do
        get do
          Heap.get_obj(listener_ref, nil)
        end

        set do
          Heap.put_obj(listener_ref, arg(args, 0, nil))
          :undefined
        end
      end
    end
  end

  defp deliver_message(channel_name, channel_id, data) do
    channel_name
    |> get_channel_listeners()
    |> Enum.each(fn {id, listener_ref} ->
      if id != channel_id do
        handler = Heap.get_obj(listener_ref, nil)

        if handler not in [nil, false, :undefined] do
          event = Heap.wrap(%{"data" => data, "type" => "message"})
          Callback.safe_invoke(handler, [event])
        end
      end
    end)
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
