defmodule QuickBEAM.JS.Parser.Validation.Bindings do
  @moduledoc "Lexical, var, import, and catch binding validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_catch_param_bindings(state, nil, _body), do: state

  def validate_catch_param_bindings(state, param, %AST.BlockStatement{body: body}) do
    param_names = binding_names(param)
    lexical_names = lexical_binding_names(body)

    if Enum.any?(param_names, &(&1 in lexical_names)) do
      add_error(state, current(state), "catch parameter conflicts with lexical declaration")
    else
      state
    end
  end

  def validate_duplicate_lexical_bindings(state, body) do
    lexical_names = lexical_binding_names(body)
    var_names = var_binding_names(body)

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

  defp lexical_binding_names(body), do: Enum.flat_map(body, &lexical_statement_names/1)

  defp lexical_statement_names(%AST.VariableDeclaration{kind: kind, declarations: declarations})
       when kind in [:let, :const] do
    Enum.flat_map(declarations, &binding_names(&1.id))
  end

  defp lexical_statement_names(%AST.ClassDeclaration{id: %AST.Identifier{name: name}}), do: [name]

  defp lexical_statement_names(%AST.ImportDeclaration{specifiers: specifiers}) do
    Enum.flat_map(specifiers, &import_specifier_names/1)
  end

  defp lexical_statement_names(_statement), do: []

  defp import_specifier_names(%{local: %AST.Identifier{name: name}}), do: [name]
  defp import_specifier_names(_specifier), do: []

  defp var_binding_names(body), do: Enum.flat_map(body, &var_statement_names/1)

  defp var_statement_names(%AST.VariableDeclaration{kind: :var, declarations: declarations}) do
    Enum.flat_map(declarations, &binding_names(&1.id))
  end

  defp var_statement_names(%AST.FunctionDeclaration{id: %AST.Identifier{name: name}}), do: [name]
  defp var_statement_names(_statement), do: []
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

  defp current(state), do: token_at(state, state.index)

  defp token_at(%{token_count: token_count, last_token: last_token}, index)
       when index >= token_count,
       do: last_token

  defp token_at(%{tokens: tokens}, index), do: elem(tokens, index)

  defp add_error(state, %Token{} = token, message) do
    error = %Error{
      message: message,
      line: token.line,
      column: token.column,
      offset: token.start
    }

    %{state | errors: [error | state.errors]}
  end
end
