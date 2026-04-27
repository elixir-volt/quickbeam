defmodule QuickBEAM.JS.Parser.Validation.ControlFlow do
  @moduledoc "Control-flow, label, break, continue, and return validation."

  alias QuickBEAM.JS.Parser.{AST, Error, Token}

  def validate_control_flow(state, body) do
    {state, _context} =
      validate_control_flow_statements(state, body, %{loop?: false, switch?: false, labels: %{}})

    state
  end

  def validate_control_flow_statements(state, statements, context) do
    Enum.reduce(statements, {state, context}, fn statement, {state, context} ->
      {validate_control_flow_statement(state, statement, context), context}
    end)
  end

  def validate_control_flow_statement(state, %AST.ReturnStatement{}, _context) do
    add_error(state, current(state), "return statement not within function")
  end

  def validate_control_flow_statement(state, %AST.BreakStatement{label: nil}, %{
        loop?: loop?,
        switch?: switch?
      }) do
    if loop? or switch?,
      do: state,
      else: add_error(state, current(state), "break statement not within loop or switch")
  end

  def validate_control_flow_statement(
        state,
        %AST.BreakStatement{label: %AST.Identifier{name: name}},
        %{labels: labels}
      ) do
    if Map.has_key?(labels, name),
      do: state,
      else: add_error(state, current(state), "undefined break label")
  end

  def validate_control_flow_statement(state, %AST.ContinueStatement{label: nil}, %{loop?: loop?}) do
    if loop?,
      do: state,
      else: add_error(state, current(state), "continue statement not within loop")
  end

  def validate_control_flow_statement(
        state,
        %AST.ContinueStatement{label: %AST.Identifier{name: name}},
        %{labels: labels}
      ) do
    if Map.get(labels, name),
      do: state,
      else: add_error(state, current(state), "undefined or non-iteration continue label")
  end

  def validate_control_flow_statement(state, %AST.BlockStatement{body: body}, context) do
    {state, _context} = validate_control_flow_statements(state, body, context)
    state
  end

  def validate_control_flow_statement(
        state,
        %AST.IfStatement{consequent: consequent, alternate: alternate},
        context
      ) do
    state
    |> validate_control_flow_statement(consequent, context)
    |> validate_control_flow_statement(alternate, context)
  end

  def validate_control_flow_statement(state, %AST.WhileStatement{body: body}, context),
    do: validate_control_flow_statement(state, body, %{context | loop?: true})

  def validate_control_flow_statement(state, %AST.DoWhileStatement{body: body}, context),
    do: validate_control_flow_statement(state, body, %{context | loop?: true})

  def validate_control_flow_statement(state, %AST.ForStatement{body: body}, context),
    do: validate_control_flow_statement(state, body, %{context | loop?: true})

  def validate_control_flow_statement(state, %AST.ForInStatement{body: body}, context),
    do: validate_control_flow_statement(state, body, %{context | loop?: true})

  def validate_control_flow_statement(state, %AST.ForOfStatement{body: body}, context),
    do: validate_control_flow_statement(state, body, %{context | loop?: true})

  def validate_control_flow_statement(state, %AST.SwitchStatement{cases: cases}, context) do
    statements = Enum.flat_map(cases, & &1.consequent)

    {state, _context} =
      validate_control_flow_statements(state, statements, %{context | switch?: true})

    state
  end

  def validate_control_flow_statement(
        state,
        %AST.TryStatement{block: block, handler: handler, finalizer: finalizer},
        context
      ) do
    state
    |> validate_control_flow_statement(block, context)
    |> validate_control_flow_statement(handler, context)
    |> validate_control_flow_statement(finalizer, context)
  end

  def validate_control_flow_statement(state, %AST.CatchClause{body: body}, context),
    do: validate_control_flow_statement(state, body, context)

  def validate_control_flow_statement(
        state,
        %AST.LabeledStatement{label: %AST.Identifier{name: name}, body: body},
        context
      ) do
    state =
      if Map.has_key?(context.labels, name) do
        add_error(state, current(state), "duplicate label")
      else
        state
      end

    label_context = %{context | labels: Map.put(context.labels, name, iteration_statement?(body))}
    validate_control_flow_statement(state, body, label_context)
  end

  def validate_control_flow_statement(state, _statement, _context), do: state

  defp iteration_statement?(%AST.WhileStatement{}), do: true
  defp iteration_statement?(%AST.DoWhileStatement{}), do: true
  defp iteration_statement?(%AST.ForStatement{}), do: true
  defp iteration_statement?(%AST.ForInStatement{}), do: true
  defp iteration_statement?(%AST.ForOfStatement{}), do: true
  defp iteration_statement?(_statement), do: false

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
