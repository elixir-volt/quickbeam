defmodule QuickBEAM.VM.Runtime.WebAPIs do
  @moduledoc "Aggregates all Web API builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  alias QuickBEAM.VM.Runtime.Constructors

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
    Events,
    EventSourceAPI,
    Fetch,
    FormData,
    Headers,
    MessageChannel,
    Navigator,
    Performance,
    Streams,
    TextEncoding,
    Timers,
    URL,
    Worker
  }

  @doc "Registers this runtime subsystem in the supplied global environment."
  def register(name, constructor), do: Constructors.register(name, constructor, %{}, nil)

  @providers [
    TextEncoding,
    URL,
    Encoding,
    Timers,
    Headers,
    Abort,
    Performance,
    Blob,
    Crypto,
    Fetch,
    Events,
    FormData,
    Streams,
    BroadcastChannel,
    Buffer,
    MessageChannel,
    Navigator,
    Compression,
    ConsoleAPI,
    Worker,
    EventSourceAPI,
    BeamAPI
  ]

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    Enum.reduce(@providers, %{}, fn provider, bindings ->
      Map.merge(bindings, provider.bindings())
    end)
  end
end
