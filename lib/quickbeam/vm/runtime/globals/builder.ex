defmodule QuickBEAM.VM.Runtime.Globals.Builder do
  @moduledoc "Builds global bindings and post-build global metadata for a runtime realm."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.Bindings, as: HostBindings

  alias QuickBEAM.VM.Runtime.Errors
  alias QuickBEAM.VM.Runtime.Globals.{GlobalThis, Registry}

  def build do
    Registry.bindings()
    |> Map.merge(Errors.bindings())
    |> cache_globals()
    |> Map.merge(HostBindings.bindings())
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
