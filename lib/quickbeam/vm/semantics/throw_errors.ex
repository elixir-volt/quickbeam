defmodule QuickBEAM.VM.Semantics.ThrowErrors do
  @moduledoc "Shared bytecode throw-error message mapping."

  def message(name, reason) do
    case reason do
      0 -> {"TypeError", "'#{name}' is read-only"}
      1 -> {"SyntaxError", "redeclaration of '#{name}'"}
      2 -> {"ReferenceError", "cannot access '#{name}' before initialization"}
      3 -> {"ReferenceError", "unsupported reference to 'super'"}
      4 -> {"TypeError", "iterator does not have a throw method"}
      _ -> {"Error", name}
    end
  end
end
