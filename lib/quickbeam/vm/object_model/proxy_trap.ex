defmodule QuickBEAM.VM.ObjectModel.ProxyTrap do
  @moduledoc "Shared Proxy trap invocation semantics."

  alias QuickBEAM.VM.Invocation

  def call(trap, args, handler), do: Invocation.invoke_with_receiver(trap, args, handler)
end
