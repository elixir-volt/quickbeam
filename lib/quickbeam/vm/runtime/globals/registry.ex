defmodule QuickBEAM.VM.Runtime.Globals.Registry do
  @moduledoc "Builds the core global binding registry before post-install metadata hooks run."

  alias QuickBEAM.VM.Runtime.{Console, JSON, Math, Reflect}
  alias QuickBEAM.VM.Runtime.Globals.Bindings

  def bindings do
    %{
      "Math" => Math.object() |> Math.install_metadata(),
      "JSON" => JSON.object() |> JSON.install_metadata(),
      "Reflect" => Reflect.object() |> Reflect.install_metadata(),
      "console" => Console.object()
    }
    |> Map.merge(Bindings.bindings())
    |> Map.merge(QuickBEAM.VM.Builtin.Discovery.bindings())
  end
end
