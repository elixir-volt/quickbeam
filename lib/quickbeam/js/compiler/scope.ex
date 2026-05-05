defmodule QuickBEAM.JS.Compiler.Scope do
  @moduledoc false

  defstruct args: %{},
            globals: MapSet.new(),
            locals: %{},
            local_names: [],
            var_refs: %{},
            arguments_alias: nil,
            self_bindings: MapSet.new()

  def new(args \\ [], globals \\ []) do
    args = Enum.with_index(args) |> Map.new()
    %__MODULE__{args: args, globals: MapSet.new(globals)}
  end

  def with_var_refs(%__MODULE__{} = scope, var_ref_map) when is_map(var_ref_map),
    do: %{scope | var_refs: var_ref_map}

  def with_arguments_alias(%__MODULE__{} = scope, param_count),
    do: %{scope | arguments_alias: param_count}

  def with_self_binding(%__MODULE__{} = scope, name) when is_binary(name),
    do: %{scope | self_bindings: MapSet.put(scope.self_bindings, name)}

  def self_binding?(%__MODULE__{} = scope, name), do: MapSet.member?(scope.self_bindings, name)

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

  def names(%__MODULE__{} = scope) do
    aliases = if Map.has_key?(scope.locals, "<arguments>"), do: ["arguments"], else: []
    Map.keys(scope.args) ++ scope.local_names ++ aliases ++ Map.keys(scope.var_refs)
  end

  def resolve(%__MODULE__{} = scope, name) when is_binary(name) do
    cond do
      name == "arguments" and Map.has_key?(scope.locals, "<arguments>") ->
        {:loc, Map.fetch!(scope.locals, "<arguments>")}

      Map.has_key?(scope.var_refs, name) ->
        {:var_ref, Map.fetch!(scope.var_refs, name)}

      Map.has_key?(scope.args, name) ->
        {:arg, Map.fetch!(scope.args, name)}

      Map.has_key?(scope.locals, name) ->
        {:loc, Map.fetch!(scope.locals, name)}

      MapSet.member?(scope.globals, name) ->
        {:global, name}

      true ->
        :error
    end
  end
end
