defmodule QuickBEAM.VM.Runtime.GlobalInstaller do
  @moduledoc "Installs global bindings and post-build global metadata for a runtime realm."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.WebAPIs

  alias QuickBEAM.VM.Runtime.{
    Errors,
    GlobalRegistry,
    GlobalThisInstaller
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
    GlobalThisInstaller.install(bindings)
    bindings
  end
end
