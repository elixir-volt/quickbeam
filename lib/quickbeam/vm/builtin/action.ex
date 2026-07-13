defmodule QuickBEAM.VM.Builtin.Action do
  @moduledoc "Wraps a validated resumable action returned by a builtin handler."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end

defmodule QuickBEAM.VM.Builtin.ContractError do
  @moduledoc "Raised when a builtin handler violates the runtime result contract."

  defexception [:module, :handler, :result]

  @impl true
  def message(%__MODULE__{module: module, handler: handler, result: result}) do
    "builtin #{inspect(module)}.#{handler}/1 returned an invalid result: #{inspect(result)}"
  end
end
