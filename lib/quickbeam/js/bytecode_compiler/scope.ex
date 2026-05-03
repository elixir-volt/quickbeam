defmodule QuickBEAM.JS.BytecodeCompiler.Scope do
  @moduledoc false

  defstruct args: %{}, globals: MapSet.new(), locals: %{}, local_names: []

  def new(args \\ [], globals \\ []) do
    args = Enum.with_index(args) |> Map.new()
    %__MODULE__{args: args, globals: MapSet.new(globals)}
  end

  def declare_local(%__MODULE__{} = scope, name) when is_binary(name) do
    if Map.has_key?(scope.locals, name) do
      scope
    else
      index = map_size(scope.locals)

      %{
        scope
        | locals: Map.put(scope.locals, name, index),
          local_names: scope.local_names ++ [name]
      }
    end
  end

  def names(%__MODULE__{} = scope), do: Map.keys(scope.args) ++ scope.local_names

  def resolve(%__MODULE__{} = scope, name) when is_binary(name) do
    cond do
      Map.has_key?(scope.args, name) -> {:arg, Map.fetch!(scope.args, name)}
      Map.has_key?(scope.locals, name) -> {:loc, Map.fetch!(scope.locals, name)}
      MapSet.member?(scope.globals, name) -> {:global, name}
      true -> :error
    end
  end
end
