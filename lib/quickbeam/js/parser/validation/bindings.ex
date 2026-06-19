defmodule QuickBEAM.JS.Parser.Validation.Bindings do
  @moduledoc "Lexical, var, import, and catch binding validation."

  alias QuickBEAM.JS.Parser.AST
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]

  def validate_catch_param_bindings(state, nil, _body), do: state

  def validate_catch_param_bindings(state, param, %AST.BlockStatement{body: body}) do
    param_names = binding_names(param)
    lexical_names = lexical_binding_names(body, false)
    function_names = body |> block_function_bindings() |> Enum.map(&elem(&1, 0))

    cond do
      duplicate_names?(param_names) ->
        add_error(state, current(state), "duplicate lexical declaration")

      Enum.any?(param_names, &(&1 in lexical_names or &1 in function_names)) ->
        add_error(state, current(state), "catch parameter conflicts with lexical declaration")

      true ->
        state
    end
  end

  def validate_duplicate_lexical_bindings(state, body) do
    validate_duplicate_bindings(state, body, false)
  end

  def validate_restricted_global_lexical_bindings(%{source_type: :script} = state, body) do
    lexical_names = lexical_binding_names(body, false)

    if "undefined" in lexical_names do
      add_error(state, current(state), "restricted global lexical binding")
    else
      state
    end
  end

  def validate_restricted_global_lexical_bindings(state, _body), do: state

  def validate_duplicate_block_bindings(state, body) do
    lexical_names = lexical_binding_names(body, false)
    function_bindings = block_function_bindings(body)
    function_names = Enum.map(function_bindings, &elem(&1, 0))
    var_names = var_binding_names(body, false)

    cond do
      duplicate_names?(lexical_names) or Enum.any?(function_names, &(&1 in lexical_names)) or
          invalid_duplicate_block_functions?(function_bindings) ->
        add_error(state, current(state), "duplicate lexical declaration")

      Enum.any?(lexical_names ++ function_names, &(&1 in var_names)) ->
        add_error(state, current(state), "lexical declaration conflicts with var declaration")

      true ->
        state
    end
  end

  defp validate_duplicate_bindings(state, body, block?) do
    lexical_names = lexical_binding_names(body, block?)
    var_names = var_binding_names(body, not block?)

    cond do
      duplicate_names?(lexical_names) ->
        add_error(state, current(state), "duplicate lexical declaration")

      Enum.any?(lexical_names, &(&1 in var_names)) ->
        add_error(state, current(state), "lexical declaration conflicts with var declaration")

      true ->
        state
    end
  end

  defp duplicate_names?(names), do: length(names) != length(Enum.uniq(names))

  defp lexical_binding_names(body, block?),
    do: Enum.flat_map(body, &lexical_statement_names(&1, block?))

  defp lexical_statement_names(
         %AST.VariableDeclaration{kind: kind, declarations: declarations},
         _block?
       )
       when kind in [:let, :const] do
    Enum.flat_map(declarations, &binding_names(&1.id))
  end

  defp lexical_statement_names(%AST.ClassDeclaration{id: %AST.Identifier{name: name}}, _block?),
    do: [name]

  defp lexical_statement_names(%AST.FunctionDeclaration{}, _block?), do: []

  defp lexical_statement_names(%AST.ImportDeclaration{specifiers: specifiers}, _block?) do
    Enum.flat_map(specifiers, &import_specifier_names/1)
  end

  defp lexical_statement_names(_statement, _block?), do: []

  defp import_specifier_names(%{local: %AST.Identifier{name: name}}), do: [name]
  defp import_specifier_names(_specifier), do: []

  defp block_function_bindings(body),
    do: Enum.flat_map(body, &block_function_statement_bindings/1)

  defp block_function_statement_bindings(%AST.FunctionDeclaration{
         id: %AST.Identifier{name: name},
         async: async?,
         generator: generator?
       }) do
    [{name, not async? and not generator?}]
  end

  defp block_function_statement_bindings(_statement), do: []

  defp invalid_duplicate_block_functions?(function_bindings) do
    function_bindings
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.any?(fn {_name, plain_function_flags} ->
      length(plain_function_flags) > 1 and not Enum.all?(plain_function_flags)
    end)
  end

  defp var_binding_names(body, include_functions?),
    do: Enum.flat_map(body, &var_statement_names(&1, include_functions?))

  defp var_statement_names(
         %AST.VariableDeclaration{kind: :var, declarations: declarations},
         _include_functions?
       ) do
    Enum.flat_map(declarations, &binding_names(&1.id))
  end

  defp var_statement_names(%AST.FunctionDeclaration{id: %AST.Identifier{name: name}}, true),
    do: [name]

  defp var_statement_names(%AST.FunctionDeclaration{}, false), do: []

  defp var_statement_names(%AST.BlockStatement{body: body}, _include_functions?),
    do: var_binding_names(body, false)

  defp var_statement_names(_statement, _include_functions?), do: []
  defp binding_names(%AST.Identifier{name: name}), do: [name]
  defp binding_names(%AST.AssignmentPattern{left: left}), do: binding_names(left)
  defp binding_names(%AST.RestElement{argument: argument}), do: binding_names(argument)

  defp binding_names(%AST.ArrayPattern{elements: elements}),
    do: Enum.flat_map(elements, &binding_names/1)

  defp binding_names(%AST.ObjectPattern{properties: properties}),
    do: Enum.flat_map(properties, &binding_names/1)

  defp binding_names(%AST.Property{value: value}), do: binding_names(value)
  defp binding_names(nil), do: []
  defp binding_names(_param), do: []
end
