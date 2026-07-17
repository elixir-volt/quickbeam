defmodule QuickBEAM.VM.Builtin.Error.Type do
  @moduledoc "Defines the declarative TypeError constructor."
  use QuickBEAM.VM.Builtin.Error.Subclass, name: "TypeError"
end
