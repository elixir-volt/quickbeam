defmodule QuickBEAM.VM.Runtime.GlobalRegistry do
  @moduledoc "Builds the core global binding registry before post-install metadata hooks run."

  alias QuickBEAM.VM.Host.Test262

  alias QuickBEAM.VM.Runtime.{
    Console,
    GlobalBindings,
    JSON,
    Math,
    Reflect
  }

  def bindings do
    %{
      "$262" => Test262.object(),
      "Math" => Math.object() |> Math.install_metadata(),
      "JSON" => JSON.object() |> JSON.install_metadata(),
      "Reflect" => Reflect.object() |> Reflect.install_metadata(),
      "console" => Console.object()
    }
    |> Map.merge(GlobalBindings.bindings())
    |> Map.merge(QuickBEAM.VM.Builtin.Discovery.bindings())
  end
end
