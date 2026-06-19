defmodule QuickBEAM.VM.Runtime.Globals.Registry do
  @moduledoc "Builds the core global binding registry before post-install metadata hooks run."

  alias QuickBEAM.VM.Runtime.{Atomics, Console, JSON, Math, Reflect}
  alias QuickBEAM.VM.Runtime.Globals.Bindings

  def bindings do
    bindings =
      %{
        "Math" => Math.object() |> Math.install_metadata(),
        "JSON" => JSON.object() |> JSON.install_metadata(),
        "Reflect" => Reflect.object() |> Reflect.install_metadata(),
        "Atomics" => Atomics.object() |> Atomics.install_metadata(),
        "console" => Console.object()
      }
      |> Map.merge(Bindings.bindings())
      |> Map.merge(QuickBEAM.VM.Builtin.Discovery.bindings())

    alias_number_parse_functions(bindings)
    bindings
  end

  defp alias_number_parse_functions(%{
         "Number" => number,
         "parseInt" => parse_int,
         "parseFloat" => parse_float
       }) do
    QuickBEAM.VM.Heap.put_ctor_static(number, "parseInt", parse_int)
    QuickBEAM.VM.Heap.put_ctor_static(number, "parseFloat", parse_float)
  end

  defp alias_number_parse_functions(_bindings), do: :ok
end
