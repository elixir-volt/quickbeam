defmodule QuickBEAM.BeamVM.Interpreter.Dispatch do
  @moduledoc false

  alias QuickBEAM.BeamVM.Builtin

  defdelegate call_builtin(fun, args, this), to: Builtin, as: :call
  defdelegate callable?(val), to: Builtin
end
