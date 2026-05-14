defmodule QuickBEAM.VM.Execution.SetterState do
  @moduledoc "Process-local marker used to sync global writes after setter invocation."

  @key :qb_setter_invoked

  def mark_invoked, do: Process.put(@key, true)

  def invoked?, do: Process.get(@key) == true

  def consume_invoked?, do: Process.delete(@key) == true

  def clear, do: Process.delete(@key)
end
