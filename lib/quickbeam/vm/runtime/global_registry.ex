defmodule QuickBEAM.VM.Runtime.GlobalRegistry do
  @moduledoc "Builds the core global binding registry before post-install metadata hooks run."

  alias QuickBEAM.VM.Runtime.{
    Console,
    FunctionInstaller,
    GlobalFunctionInstaller,
    JSON,
    Math,
    Reflect,
    Test262Host
  }

  def bindings do
    %{
      "$262" => Test262Host.object(),
      "Function" => FunctionInstaller.constructor(),
      "Math" => Math.object() |> Math.install_metadata(),
      "JSON" => JSON.object() |> JSON.install_metadata(),
      "Reflect" => Reflect.object() |> Reflect.install_metadata(),
      "console" => Console.object()
    }
    |> Map.merge(GlobalFunctionInstaller.bindings())
    |> Map.merge(QuickBEAM.VM.Builtin.Discovery.bindings())
  end
end
