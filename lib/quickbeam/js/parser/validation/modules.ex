defmodule QuickBEAM.JS.Parser.Validation.Modules do
  @moduledoc "Module declaration validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_module_declarations(%{source_type: :module} = state, _body), do: state

  def validate_module_declarations(state, body) do
    if Enum.any?(body, &module_declaration?/1) do
      add_error(state, current(state), "import/export declarations only allowed in modules")
    else
      state
    end
  end

  defp module_declaration?(%AST.ImportDeclaration{}), do: true
  defp module_declaration?(%AST.ExportNamedDeclaration{}), do: true
  defp module_declaration?(%AST.ExportDefaultDeclaration{}), do: true
  defp module_declaration?(%AST.ExportAllDeclaration{}), do: true
  defp module_declaration?(_statement), do: false

  def validate_nested_module_declarations(state, body) do
    if Enum.any?(body, &nested_module_declaration?/1) do
      add_error(state, current(state), "import/export declarations only allowed at top level")
    else
      state
    end
  end

  defp nested_module_declaration?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &module_or_nested_declaration?/1)

  defp nested_module_declaration?(%AST.FunctionDeclaration{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.FunctionExpression{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.ArrowFunctionExpression{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.IfStatement{consequent: consequent, alternate: alternate}) do
    module_or_nested_declaration?(consequent) or module_or_nested_declaration?(alternate)
  end

  defp nested_module_declaration?(%AST.WhileStatement{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.DoWhileStatement{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.ForStatement{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.ForInStatement{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.ForOfStatement{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.LabeledStatement{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(%AST.SwitchStatement{cases: cases}) do
    cases
    |> Enum.flat_map(& &1.consequent)
    |> Enum.any?(&module_or_nested_declaration?/1)
  end

  defp nested_module_declaration?(%AST.TryStatement{
         block: block,
         handler: handler,
         finalizer: finalizer
       }) do
    module_or_nested_declaration?(block) or module_or_nested_declaration?(handler) or
      module_or_nested_declaration?(finalizer)
  end

  defp nested_module_declaration?(%AST.CatchClause{body: body}),
    do: module_or_nested_declaration?(body)

  defp nested_module_declaration?(_statement), do: false

  defp module_or_nested_declaration?(nil), do: false

  defp module_or_nested_declaration?(statement),
    do: module_declaration?(statement) or nested_module_declaration?(statement)

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
