defmodule QuickBEAM.VM.Runtime.WebAPIs do
  @moduledoc "Aggregates all Web API builtins for BEAM mode."

  alias QuickBEAM.VM.Runtime.Web.{
    Abort,
    Blob,
    Crypto,
    Encoding,
    Fetch,
    Headers,
    Performance,
    TextEncoding,
    Timers,
    URL
  }

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
  end
end
