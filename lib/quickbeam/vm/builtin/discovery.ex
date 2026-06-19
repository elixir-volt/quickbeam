defmodule QuickBEAM.VM.Builtin.Discovery do
  @moduledoc "Discovers builtin definitions declared by runtime modules."

  alias QuickBEAM.VM.Builtin.Installer

  @phase_order %{
    core: 0,
    fundamental: 10,
    collections: 20,
    weak_refs: 30,
    runtime: 100
  }

  @doc "Returns loaded application modules that declare builtin definitions."
  def modules do
    :quickbeam
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and
        (function_exported?(module, :builtin_definition, 0) or
           function_exported?(module, :builtin_definitions, 0))
    end)
  end

  @doc "Returns discovered builtin definitions in deterministic installation order."
  def definitions do
    modules()
    |> Enum.flat_map(&module_definitions/1)
    |> Enum.sort_by(fn definition ->
      {Map.get(@phase_order, definition.phase, 1_000), definition.name}
    end)
  end

  @doc "Installs all discovered builtin definitions and returns global bindings."
  def bindings do
    definitions()
    |> Installer.install_all()
  end

  defp module_definitions(module) do
    cond do
      function_exported?(module, :builtin_definitions, 0) ->
        List.wrap(module.builtin_definitions())

      function_exported?(module, :builtin_definition, 0) ->
        [module.builtin_definition()]

      true ->
        []
    end
  end
end
