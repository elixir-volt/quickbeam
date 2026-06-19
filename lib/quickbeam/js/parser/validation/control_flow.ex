defmodule QuickBEAM.JS.Parser.Validation.ControlFlow do
  @moduledoc "Control-flow, label, break, continue, and return validation."

  alias QuickBEAM.JS.Parser.AST
  import QuickBEAM.JS.Parser.Validation.Helpers, only: [add_error: 3, current: 1]

  def validate_control_flow(state, body) do
    {state, _context} =
      validate_control_flow_statements(state, body, %{
        loop?: false,
        switch?: false,
        labels: %{},
        function?: false
      })

    state
  end

  def validate_control_flow_statements(state, statements, context) do
    Enum.reduce(statements, {state, context}, fn statement, {state, context} ->
      {validate_control_flow_statement(state, statement, context), context}
    end)
  end

  def validate_control_flow_statement(state, %AST.ReturnStatement{}, %{function?: function?}) do
    if function?,
      do: state,
      else: add_error(state, current(state), "return statement not within function")
  end

  def validate_control_flow_statement(
        state,
        %AST.ExpressionStatement{expression: expression},
        context
      ),
      do: validate_control_flow_expression(state, expression, context)

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

  def validate_control_flow_statement(state, %AST.ClassDeclaration{body: body}, _context) do
    Enum.reduce(body, state, fn
      %AST.StaticBlock{body: block_body}, state ->
        {state, _context} =
          validate_control_flow_statements(state, block_body, %{
            loop?: false,
            switch?: false,
            labels: %{},
            function?: false
          })

        state

      _element, state ->
        state
    end)
  end

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

  defp validate_control_flow_expression(
         state,
         %AST.FunctionExpression{body: %AST.BlockStatement{body: body}},
         _context
       ) do
    {state, _context} =
      validate_control_flow_statements(state, body, %{
        loop?: false,
        switch?: false,
        labels: %{},
        function?: true
      })

    state
  end

  defp validate_control_flow_expression(
         state,
         %AST.CallExpression{callee: callee, arguments: arguments},
         context
       ) do
    state = validate_control_flow_expression(state, callee, context)
    Enum.reduce(arguments, state, &validate_control_flow_expression(&2, &1, context))
  end

  defp validate_control_flow_expression(
         state,
         %AST.AssignmentExpression{left: left, right: right},
         context
       ) do
    state
    |> validate_control_flow_expression(left, context)
    |> validate_control_flow_expression(right, context)
  end

  defp validate_control_flow_expression(state, _expression, _context), do: state

  defp iteration_statement?(%AST.WhileStatement{}), do: true
  defp iteration_statement?(%AST.DoWhileStatement{}), do: true
  defp iteration_statement?(%AST.ForStatement{}), do: true
  defp iteration_statement?(%AST.ForInStatement{}), do: true
  defp iteration_statement?(%AST.ForOfStatement{}), do: true
  defp iteration_statement?(_statement), do: false
end
