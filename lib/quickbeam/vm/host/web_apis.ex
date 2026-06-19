defmodule QuickBEAM.VM.Host.WebAPIs do
  @moduledoc "Aggregates all Web API builtins for BEAM mode."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  alias QuickBEAM.VM.Runtime.ConstructorRegistry, as: Constructors
  alias QuickBEAM.VM.Host.BEAM

  alias QuickBEAM.VM.Host.Web.{
    Abort,
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

  @doc "Registers a set of host constructors from `{name, callback}` declarations."
  def register_constructors(declarations) do
    Map.new(declarations, fn {name, constructor} -> {name, register(name, constructor)} end)
  end

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
    BEAM
  ]

  @doc "Returns the JavaScript global bindings provided by this module."
  def bindings do
    Enum.reduce(@providers, %{}, fn provider, bindings ->
      Map.merge(bindings, provider.bindings())
    end)
  end
end
