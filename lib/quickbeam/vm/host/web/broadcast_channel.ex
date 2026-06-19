defmodule QuickBEAM.VM.Host.Web.BroadcastChannel do
  @moduledoc "BroadcastChannel builtin for BEAM mode — in-process pub/sub via process dictionary."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  import QuickBEAM.VM.Builtin, only: [arg: 3, object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.Callback
  alias QuickBEAM.VM.Host.Web.BroadcastChannel.State
  alias QuickBEAM.VM.Host.WebAPIs

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    %{"BroadcastChannel" => WebAPIs.register("BroadcastChannel", &build_channel/2)}
  end

  defp build_channel(args, _this) do
    channel_name = args |> List.first("") |> to_string()
    listener_ref = make_ref()
    Heap.put_obj(listener_ref, nil)

    channel_id = make_ref()
    State.register(channel_name, channel_id, listener_ref)

    object do
      prop("name", channel_name)

      method "postMessage" do
        data = arg(args, 0, :undefined)
        deliver_message(channel_name, channel_id, data)
        :undefined
      end

      method "close" do
        State.unregister(channel_name, channel_id)
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
    |> State.listeners()
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
end
