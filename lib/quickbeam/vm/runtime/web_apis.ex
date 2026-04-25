defmodule QuickBEAM.VM.Runtime.WebAPIs do
  @moduledoc "Aggregates all Web API builtins for BEAM mode."

  alias QuickBEAM.VM.Heap

  alias QuickBEAM.VM.Runtime.Web.{
    Abort,
    BeamAPI,
    Blob,
    BroadcastChannel,
    Buffer,
    Compression,
    ConsoleAPI,
    Crypto,
    Encoding,
    EventSourceAPI,
    Events,
    Fetch,
    FormData,
    Headers,
    MessageChannel,
    Navigator,
    Performance,
    Streams,
    SubtleCrypto,
    TextEncoding,
    Timers,
    URL,
    Worker
  }

  def register(name, constructor) do
    ctor = {:builtin, name, constructor}
    proto = Heap.wrap(%{"constructor" => ctor})
    Heap.put_class_proto(ctor, proto)
    Heap.put_ctor_static(ctor, "prototype", proto)
    ctor
  end

  def bindings do
    %{}
    |> Map.merge(TextEncoding.bindings())
    |> Map.merge(URL.bindings())
    |> Map.merge(Encoding.bindings())
    |> Map.merge(Timers.bindings())
    |> Map.merge(Headers.bindings())
    |> Map.merge(Abort.bindings())
    |> Map.merge(Performance.bindings())
    |> Map.merge(Blob.bindings())
    |> Map.merge(Crypto.bindings())
    |> Map.merge(Fetch.bindings())
    |> Map.merge(Events.bindings())
    |> Map.merge(FormData.bindings())
    |> Map.merge(Streams.bindings())
    |> Map.merge(BroadcastChannel.bindings())
    |> Map.merge(Buffer.bindings())
    |> Map.merge(MessageChannel.bindings())
    |> Map.merge(Navigator.bindings())
    |> Map.merge(Compression.bindings())
    |> Map.merge(ConsoleAPI.bindings())
    |> Map.merge(Worker.bindings())
    |> Map.merge(EventSourceAPI.bindings())
    |> Map.merge(BeamAPI.bindings())
    |> Map.merge(subtle_crypto_in_crypto())
  end

  defp subtle_crypto_in_crypto do
    %{}
  end
end
