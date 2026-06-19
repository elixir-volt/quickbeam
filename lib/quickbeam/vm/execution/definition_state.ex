defmodule QuickBEAM.VM.Execution.DefinitionState do
  @moduledoc "Process-local markers for definition operations that span object-model helpers."

  def with_static_method_definition(target, fun) do
    key = static_method_key(target)
    if match?({:obj, _}, target), do: :ok, else: Process.put(key, true)

    try do
      fun.()
    after
      Process.delete(key)
    end
  end

  def static_method_definition?(target), do: Process.get(static_method_key(target)) == true

  defp static_method_key(target), do: {:qb_define_static_method, target}
end
