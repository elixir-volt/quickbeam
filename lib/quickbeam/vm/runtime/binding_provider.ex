defmodule QuickBEAM.VM.Runtime.BindingProvider do
  @moduledoc "Contract for runtime modules that contribute global JS bindings."

  @callback bindings() :: map()
end
