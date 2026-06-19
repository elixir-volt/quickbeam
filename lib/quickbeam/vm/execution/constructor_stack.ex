defmodule QuickBEAM.VM.Execution.ConstructorStack do
  @moduledoc "Process-local constructor-call stack used for compiled-runtime error context."

  @key :qb_constructor_call_stack

  def get, do: Process.get(@key)

  def with_stack(stack, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, stack)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
