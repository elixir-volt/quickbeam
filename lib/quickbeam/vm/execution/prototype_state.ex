defmodule QuickBEAM.VM.Execution.PrototypeState do
  @moduledoc "Process-local caches for lazily materialized VM prototype objects."

  def cached(key, build) do
    case Process.get(key) do
      {:obj, _} = proto ->
        proto

      nil ->
        put_built(key, build)

      _other ->
        put_built(key, build)
    end
  end

  def cached_any(key, build) do
    case Process.get(key) do
      nil ->
        put_built(key, build)

      value ->
        value
    end
  end

  defp put_built(key, build) do
    value = build.()
    Process.put(key, value)
    value
  end
end
