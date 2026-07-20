defmodule QuickBEAM.VM.Builtin.Contract.Error do
  @moduledoc "Raised when a builtin handler violates the runtime result contract."

  defexception [:module, :handler, :result]

  @doc "Formats the invalid builtin handler result."
  @impl true
  def message(%__MODULE__{module: module, handler: handler, result: result}) do
    "builtin #{inspect(module)}.#{handler}/1 returned an invalid result: #{inspect(result)}"
  end
end
