defmodule QuickBEAM.JS.Parser do
  @moduledoc "Experimental hand-written JavaScript parser for QuickBEAM."

  alias QuickBEAM.JS.Parser.AST
  alias QuickBEAM.JS.Parser.{Error, Lexer, Token}

  defstruct tokens: [], index: 0, errors: [], source_type: :script

  @type t :: %__MODULE__{}

  @assignment_ops ~w[= += -= *= /= %= **= <<= >>= >>>= &= ^= |= &&= ||= ??=]
  @logical_ops ~w[|| && ??]
  @unary_ops ~w[! ~ + - typeof void delete]
  @update_ops ~w[++ --]

  @precedence %{
    "," => {1, :left},
    "=" => {2, :right},
    "+=" => {2, :right},
    "-=" => {2, :right},
    "*=" => {2, :right},
    "/=" => {2, :right},
    "%=" => {2, :right},
    "**=" => {2, :right},
    "<<=" => {2, :right},
    ">>=" => {2, :right},
    ">>>=" => {2, :right},
    "&=" => {2, :right},
    "^=" => {2, :right},
    "|=" => {2, :right},
    "&&=" => {2, :right},
    "||=" => {2, :right},
    "??=" => {2, :right},
    "?" => {3, :right},
    "??" => {4, :left},
    "||" => {5, :left},
    "&&" => {6, :left},
    "|" => {7, :left},
    "^" => {8, :left},
    "&" => {9, :left},
    "==" => {10, :left},
    "!=" => {10, :left},
    "===" => {10, :left},
    "!==" => {10, :left},
    "<" => {11, :left},
    ">" => {11, :left},
    "<=" => {11, :left},
    ">=" => {11, :left},
    "in" => {11, :left},
    "instanceof" => {11, :left},
    "<<" => {12, :left},
    ">>" => {12, :left},
    ">>>" => {12, :left},
    "+" => {13, :left},
    "-" => {13, :left},
    "*" => {14, :left},
    "/" => {14, :left},
    "%" => {14, :left},
    "**" => {15, :right}
  }

  @doc "Parses JavaScript source into the experimental QuickBEAM JS AST."
  def parse(source, opts \\ []) when is_binary(source) do
    source_type = Keyword.get(opts, :source_type, :script)

    with {:ok, tokens} <- Lexer.tokenize(source) do
      state = %__MODULE__{tokens: tokens, source_type: source_type}
      {program, state} = parse_program(state)

      case state.errors do
        [] -> {:ok, program}
        errors -> {:error, program, Enum.reverse(errors)}
      end
    else
      {:error, tokens, errors} ->
        state = %__MODULE__{tokens: tokens, source_type: source_type, errors: errors}
        {program, state} = parse_program(state)
        {:error, program, Enum.reverse(state.errors)}
    end
  end

  @doc "Parses JavaScript source and raises when syntax errors are produced."
  def parse!(source, opts \\ []) do
    case parse(source, opts) do
      {:ok, ast} -> ast
      {:error, _ast, [error | _]} -> raise SyntaxError, message: error.message
      {:error, _ast, []} -> raise SyntaxError, message: "failed to parse JavaScript"
    end
  end

  defp parse_program(state) do
    {body, state} = parse_statement_list(state, [])
    {%AST.Program{source_type: state.source_type, body: body}, state}
  end

  defp parse_statement_list(state, acc) do
    cond do
      eof?(state) ->
        {Enum.reverse(acc), state}

      match_value?(state, "}") ->
        {Enum.reverse(acc), state}

      true ->
        {statement, state} = parse_statement(state)
        parse_statement_list(state, [statement | acc])
    end
  end

  defp parse_statement(state) do
    cond do
      match_value?(state, ";") ->
        {%AST.EmptyStatement{}, advance(state)}

      keyword?(state, "var") or keyword?(state, "let") or keyword?(state, "const") ->
        parse_variable_declaration(state)

      keyword?(state, "return") ->
        parse_return_statement(state)

      true ->
        parse_expression_statement(state)
    end
  end

  defp parse_variable_declaration(state) do
    {kind, state} = consume_keyword_value(state)
    {declarations, state} = parse_declarators(state, [])
    state = consume_semicolon(state)
    {%AST.VariableDeclaration{kind: String.to_atom(kind), declarations: declarations}, state}
  end

  defp parse_declarators(state, acc) do
    {id, state} = parse_binding_identifier(state)

    {init, state} =
      if match_value?(state, "=") do
        state = advance(state)
        parse_expression(state, 2)
      else
        {nil, state}
      end

    declarator = %AST.VariableDeclarator{id: id, init: init}

    if match_value?(state, ",") do
      parse_declarators(advance(state), [declarator | acc])
    else
      {Enum.reverse([declarator | acc]), state}
    end
  end

  defp parse_binding_identifier(state) do
    token = current(state)

    case token.type do
      :identifier ->
        {%AST.Identifier{name: token.value}, advance(state)}

      _ ->
        {%AST.Identifier{name: ""},
         add_error(state, token, "expected binding identifier") |> recover_expression()}
    end
  end

  defp parse_return_statement(state) do
    state = advance(state)

    if eof?(state) or current(state).before_line_terminator? or statement_end?(state) do
      {%AST.ReturnStatement{}, consume_semicolon(state)}
    else
      {argument, state} = parse_expression(state, 0)
      {%AST.ReturnStatement{argument: argument}, consume_semicolon(state)}
    end
  end

  defp parse_expression_statement(state) do
    {expr, state} = parse_expression(state, 0)
    {%AST.ExpressionStatement{expression: expr}, consume_semicolon(state)}
  end

  defp parse_expression(state, min_precedence) do
    {left, state} = parse_prefix(state)
    parse_expression_tail(state, left, min_precedence)
  end

  defp parse_expression_tail(state, left, min_precedence) do
    state = parse_postfix_tail(state, left)

    case state do
      {left, state} -> parse_binary_tail(state, left, min_precedence)
    end
  end

  defp parse_postfix_tail(state, left) do
    cond do
      match_value?(state, "(") ->
        {arguments, state} = parse_arguments(advance(state), [])
        parse_postfix_tail(state, %AST.CallExpression{callee: left, arguments: arguments})

      match_value?(state, ".") ->
        state = advance(state)
        {property, state} = parse_property_identifier(state)

        parse_postfix_tail(state, %AST.MemberExpression{
          object: left,
          property: property,
          computed: false
        })

      match_value?(state, "[") ->
        state = advance(state)
        {property, state} = parse_expression(state, 0)
        state = expect_value(state, "]")

        parse_postfix_tail(state, %AST.MemberExpression{
          object: left,
          property: property,
          computed: true
        })

      match_value?(state, @update_ops) and not current(state).before_line_terminator? ->
        token = current(state)

        {%AST.UpdateExpression{operator: token.value, argument: left, prefix: false},
         advance(state)}

      true ->
        {left, state}
    end
  end

  defp parse_binary_tail(state, left, min_precedence) do
    token = current(state)
    operator = operator_value(token)

    case Map.get(@precedence, operator) do
      {precedence, associativity} when precedence >= min_precedence ->
        state = advance(state)

        if operator == "?" do
          parse_conditional_tail(state, left, precedence)
        else
          next_min = if associativity == :left, do: precedence + 1, else: precedence
          {right, state} = parse_expression(state, next_min)
          expr = binary_node(operator, left, right)
          parse_binary_tail(state, expr, min_precedence)
        end

      _ ->
        {left, state}
    end
  end

  defp parse_conditional_tail(state, test, precedence) do
    {consequent, state} = parse_expression(state, 0)
    state = expect_value(state, ":")
    {alternate, state} = parse_expression(state, precedence)

    parse_binary_tail(
      state,
      %AST.ConditionalExpression{test: test, consequent: consequent, alternate: alternate},
      0
    )
  end

  defp parse_prefix(state) do
    token = current(state)

    cond do
      match_value?(state, "(") ->
        state = advance(state)
        {expr, state} = parse_expression(state, 0)
        {expr, expect_value(state, ")")}

      match_value?(state, @update_ops) ->
        state = advance(state)
        {argument, state} = parse_prefix(state)
        {%AST.UpdateExpression{operator: token.value, argument: argument, prefix: true}, state}

      operator_value(token) in @unary_ops ->
        state = advance(state)
        {argument, state} = parse_prefix(state)
        {%AST.UnaryExpression{operator: operator_value(token), argument: argument}, state}

      token.type in [:number, :string, :boolean, :null] ->
        {%AST.Literal{value: token.value, raw: token.raw}, advance(state)}

      token.type == :identifier or token.value in ["this", "super"] ->
        {%AST.Identifier{name: token.value}, advance(state)}

      true ->
        {%AST.Literal{value: nil, raw: ""},
         add_error(state, token, "expected expression") |> recover_expression()}
    end
  end

  defp parse_arguments(state, acc) do
    cond do
      eof?(state) ->
        {Enum.reverse(acc), add_error(state, current(state), "unterminated argument list")}

      match_value?(state, ")") ->
        {Enum.reverse(acc), advance(state)}

      true ->
        {arg, state} = parse_expression(state, 2)

        cond do
          match_value?(state, ",") -> parse_arguments(advance(state), [arg | acc])
          match_value?(state, ")") -> {Enum.reverse([arg | acc]), advance(state)}
          true -> {Enum.reverse([arg | acc]), expect_value(state, ")")}
        end
    end
  end

  defp parse_property_identifier(state) do
    token = current(state)

    if token.type in [:identifier, :keyword] do
      {%AST.Identifier{name: token.value}, advance(state)}
    else
      {%AST.Identifier{name: ""}, add_error(state, token, "expected property name")}
    end
  end

  defp binary_node(operator, left, right) when operator in @assignment_ops do
    %AST.AssignmentExpression{operator: operator, left: left, right: right}
  end

  defp binary_node(operator, left, right) when operator in @logical_ops do
    %AST.LogicalExpression{operator: operator, left: left, right: right}
  end

  defp binary_node(operator, left, right) do
    %AST.BinaryExpression{operator: operator, left: left, right: right}
  end

  defp consume_semicolon(state) do
    cond do
      match_value?(state, ";") -> advance(state)
      eof?(state) -> state
      current(state).before_line_terminator? -> state
      true -> state
    end
  end

  defp statement_end?(state), do: match_value?(state, [";", "}"])

  defp expect_value(state, value) do
    if match_value?(state, value),
      do: advance(state),
      else: add_error(state, current(state), "expected #{value}")
  end

  defp recover_expression(state) do
    if eof?(state) or statement_end?(state) or match_value?(state, ",") do
      state
    else
      state |> advance() |> recover_expression()
    end
  end

  defp consume_keyword_value(state), do: {current(state).value, advance(state)}

  defp keyword?(state, keyword),
    do: current(state).type == :keyword and current(state).value == keyword

  defp match_value?(state, values) when is_list(values), do: current(state).value in values
  defp match_value?(state, value), do: current(state).value == value

  defp operator_value(%Token{type: :keyword, value: value})
       when value in ["in", "instanceof", "typeof", "void", "delete"], do: value

  defp operator_value(%Token{value: value}), do: value

  defp current(%__MODULE__{tokens: tokens, index: index}),
    do: Enum.at(tokens, index) || List.last(tokens)

  defp advance(%__MODULE__{} = state),
    do: %{state | index: min(state.index + 1, length(state.tokens) - 1)}

  defp eof?(state), do: current(state).type == :eof

  defp add_error(state, %Token{} = token, message) do
    error = %Error{message: message, line: token.line, column: token.column, offset: token.start}
    %{state | errors: [error | state.errors]}
  end
end
