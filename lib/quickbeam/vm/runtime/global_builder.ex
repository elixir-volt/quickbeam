defmodule QuickBEAM.VM.Runtime.GlobalBuilder do
  @moduledoc "Builds global bindings and post-build global metadata for a runtime realm."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.WebAPIs

  alias QuickBEAM.VM.Runtime.{
    Errors,
    GlobalRegistry,
    GlobalThis
  }

  def build do
    GlobalRegistry.bindings()
    |> Map.merge(Errors.bindings())
    |> cache_globals()
    |> Map.merge(WebAPIs.bindings())
    |> install_global_this()
    |> cache_globals()
  end

  defp cache_globals(bindings) do
    Heap.put_global_cache(bindings)
    bindings
  end

  defp install_global_this(bindings) do
    GlobalThis.install(bindings)
    bindings
  end
end
