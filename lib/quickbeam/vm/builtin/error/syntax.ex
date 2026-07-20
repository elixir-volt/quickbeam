defmodule QuickBEAM.VM.Builtin.Error.Syntax do
  @moduledoc "Defines the declarative SyntaxError constructor."
  use QuickBEAM.VM.Builtin.Error.Subclass, name: "SyntaxError"
end
