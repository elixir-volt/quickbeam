defmodule QuickBEAM.JS.Parser.Validation.Strict.AnnexB do
  @moduledoc "Strict-mode validation for Annex B statement-position exceptions."

  alias QuickBEAM.JS.Parser.AST
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]

  def validate_no_if_function_declarations(state, statements) when is_list(statements) do
    if Enum.any?(statements, &single_statement_function_declaration?/1) do
      add_error(
        state,
        current(state),
        "function declarations can't appear in single-statement context"
      )
    else
      state
    end
  end

  def validate_no_for_in_initializers(state, statements) when is_list(statements) do
    if Enum.any?(statements, &for_in_initializer_statement?/1) do
      add_error(state, current(state), "for-in/of declaration cannot have initializer")
    else
      state
    end
  end

  def validate_no_duplicate_block_function_declarations(state, statements)
      when is_list(statements) do
    if Enum.any?(statements, &duplicate_block_function_declaration?/1) do
      add_error(state, current(state), "duplicate lexical declaration")
    else
      state
    end
  end

  def validate_no_duplicate_switch_function_declarations(state, statements)
      when is_list(statements) do
    if Enum.any?(statements, &duplicate_switch_function_declaration?/1) do
      add_error(state, current(state), "duplicate lexical declaration")
    else
      state
    end
  end

  defp single_statement_function_declaration?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &single_statement_function_declaration?/1)

  defp single_statement_function_declaration?(%AST.IfStatement{
         consequent: consequent,
         alternate: alternate
       }) do
    match?(%AST.FunctionDeclaration{}, consequent) or
      match?(%AST.FunctionDeclaration{}, alternate) or
      single_statement_function_declaration?(consequent) or
      single_statement_function_declaration?(alternate)
  end

  defp single_statement_function_declaration?(%AST.LabeledStatement{body: body}),
    do:
      match?(%AST.FunctionDeclaration{}, body) or
        single_statement_function_declaration?(body)

  defp single_statement_function_declaration?(_statement), do: false

  defp for_in_initializer_statement?(%AST.ForInStatement{
         left: %AST.VariableDeclaration{declarations: declarations}
       }),
       do:
         Enum.any?(
           declarations,
           &match?(%AST.VariableDeclarator{init: init} when not is_nil(init), &1)
         )

  defp for_in_initializer_statement?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &for_in_initializer_statement?/1)

  defp for_in_initializer_statement?(%AST.IfStatement{
         consequent: consequent,
         alternate: alternate
       }),
       do:
         for_in_initializer_statement?(consequent) or
           for_in_initializer_statement?(alternate)

  defp for_in_initializer_statement?(_statement), do: false

  defp duplicate_block_function_declaration?(%AST.BlockStatement{body: body}) do
    function_names =
      body
      |> Enum.flat_map(fn
        %AST.FunctionDeclaration{id: %AST.Identifier{name: name}} -> [name]
        _statement -> []
      end)

    length(function_names) != length(Enum.uniq(function_names)) or
      Enum.any?(body, &duplicate_block_function_declaration?/1)
  end

  defp duplicate_block_function_declaration?(%AST.IfStatement{
         consequent: consequent,
         alternate: alternate
       }),
       do:
         duplicate_block_function_declaration?(consequent) or
           duplicate_block_function_declaration?(alternate)

  defp duplicate_block_function_declaration?(_statement), do: false

  defp duplicate_switch_function_declaration?(%AST.SwitchStatement{cases: cases}) do
    names =
      cases
      |> Enum.flat_map(& &1.consequent)
      |> Enum.flat_map(fn
        %AST.FunctionDeclaration{id: %AST.Identifier{name: name}} -> [name]
        _statement -> []
      end)

    length(names) != length(Enum.uniq(names))
  end

  defp duplicate_switch_function_declaration?(%AST.BlockStatement{body: body}),
    do: Enum.any?(body, &duplicate_switch_function_declaration?/1)

  defp duplicate_switch_function_declaration?(%AST.IfStatement{
         consequent: consequent,
         alternate: alternate
       }),
       do:
         duplicate_switch_function_declaration?(consequent) or
           duplicate_switch_function_declaration?(alternate)

  defp duplicate_switch_function_declaration?(_statement), do: false
end
