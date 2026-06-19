defmodule QuickBEAM.VM.Host.Bindings do
  @moduledoc "Aggregates host-provided global bindings."

  @behaviour QuickBEAM.VM.Runtime.BindingProvider

  alias QuickBEAM.VM.Host.{Test262, WebAPIs}

  @providers [WebAPIs, Test262]

  @impl true
  def bindings do
    Enum.reduce(@providers, %{}, fn provider, bindings ->
      Map.merge(bindings, provider.bindings())
    end)
  end
end
