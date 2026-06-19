defmodule QuickBEAM.JS.Parser.Statements do
  @moduledoc "Statement and declaration grammar for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp parse_program(state) do
        {body, state} = parse_statement_list(state, [])

        state =
          state
          |> Validation.validate_module_declarations(body)
          |> Validation.validate_nested_module_declarations(body)
          |> Validation.validate_yield_context(body)
          |> Validation.validate_await_context(body)
          |> Validation.validate_new_target_context(body)
          |> Validation.validate_import_meta_context(body)
          |> Validation.validate_super_context(body)
          |> Validation.validate_class_super_calls(body)
          |> Validation.validate_class_field_arguments(body)
          |> Validation.validate_duplicate_private_names(body)
          |> Validation.validate_declared_private_names(body)
          |> Validation.validate_private_delete(body)
          |> Validation.validate_private_super_access(body)
          |> Validation.validate_private_in_expressions(body)
          |> Validation.validate_duplicate_proto_initializers(body)
          |> Validation.validate_object_initializers(body)
          |> Validation.validate_duplicate_lexical_bindings(body)
          |> Validation.validate_restricted_global_lexical_bindings(body)
          |> Validation.validate_strict_program_bindings(body)
          |> Validation.validate_control_flow(body)

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
        case current(state) do
          %Token{value: ";"} ->
            {%AST.EmptyStatement{}, advance(state)}

          %Token{value: "{"} ->
            parse_block_statement(state)

          %Token{type: :keyword, value: "import"} ->
            if peek_value(state) in ["(", "."] do
              parse_expression_statement(state)
            else
              parse_import_declaration(state)
            end

          %Token{type: :keyword, value: "export"} ->
            parse_export_declaration(state)

          %Token{type: :keyword, value: "let"} = token when state.source_type == :script ->
            if token.raw != "let" or peek_value(state) == "=" or
                 (peek(state).before_line_terminator? and
                    peek_value(state) not in let_line_terminator_binding_starters(state)) do
              parse_expression_statement(state)
            else
              parse_variable_declaration(state)
            end

          %Token{type: :keyword, value: value} when value in ["var", "let", "const"] ->
            parse_variable_declaration(state)

          %Token{type: :identifier, value: "using"} ->
            parse_using_declaration(state, false)

          %Token{type: :keyword, value: "await"} ->
            cond do
              using_after_await?(state) -> parse_using_declaration(state, true)
              label_start?(state) -> parse_labeled_statement(state)
              true -> parse_expression_statement(state)
            end

          %Token{type: :keyword, value: "return"} ->
            parse_return_statement(state)

          %Token{type: :keyword, value: "throw"} ->
            parse_throw_statement(state)

          %Token{type: :keyword, value: "debugger"} ->
            {%AST.DebuggerStatement{}, state |> advance() |> consume_semicolon()}

          %Token{type: :keyword, value: "break"} ->
            parse_break_statement(state)

          %Token{type: :keyword, value: "continue"} ->
            parse_continue_statement(state)

          %Token{type: :keyword, value: "if"} ->
            parse_if_statement(state)

          %Token{type: :keyword, value: "while"} ->
            parse_while_statement(state)

          %Token{type: :keyword, value: "for"} ->
            parse_for_statement(state, false)

          %Token{type: :keyword, value: "do"} ->
            parse_do_while_statement(state)

          %Token{type: :keyword, value: "with"} ->
            parse_with_statement(state)

          %Token{type: :keyword, value: "switch"} ->
            parse_switch_statement(state)

          %Token{type: :keyword, value: "try"} ->
            parse_try_statement(state)

          %Token{type: :keyword, value: "function"} ->
            parse_function_declaration(state)

          %Token{type: :keyword, value: "async"} ->
            cond do
              peek_value(state) == "function" -> parse_function_declaration(state)
              label_start?(state) -> parse_labeled_statement(state)
              true -> parse_expression_statement(state)
            end

          %Token{type: :keyword, value: "class"} ->
            parse_class_declaration(state)

          _token ->
            if label_start?(state),
              do: parse_labeled_statement(state),
              else: parse_expression_statement(state)
        end
      end

      defp parse_block_statement(state) do
        previous_block_depth = state.block_depth
        state = advance(%{state | block_depth: previous_block_depth + 1})
        {body, state} = parse_statement_list(state, [])
        state = Validation.validate_duplicate_block_bindings(state, body)
        state = expect_value(state, "}")
        {%AST.BlockStatement{body: body}, %{state | block_depth: previous_block_depth}}
      end

      defp let_line_terminator_binding_starters(%{await_allowed?: true}),
        do: ["[", "let", "yield", "await"]

      defp let_line_terminator_binding_starters(_state), do: ["[", "let", "yield"]

      defp parse_variable_declaration(state) do
        {kind, state} = consume_keyword_value(state)
        {declarations, state} = parse_declarators(state, [])
        state = validate_const_initializers(state, kind, declarations)
        state = validate_lexical_let_bindings(state, kind, declarations)
        state = consume_semicolon(state)
        {%AST.VariableDeclaration{kind: String.to_atom(kind), declarations: declarations}, state}
      end

      defp validate_const_initializers(state, "const", declarations) do
        if Enum.any?(declarations, &is_nil(&1.init)),
          do: add_error(state, current(state), "missing initializer in const declaration"),
          else: state
      end

      defp validate_const_initializers(state, _kind, _declarations), do: state

      defp validate_lexical_let_bindings(state, kind, declarations)
           when kind in ["let", "const"] do
        if Enum.any?(declarations, &binding_contains_name?(&1.id, "let")) do
          add_error(state, current(state), "lexical declaration cannot bind let")
        else
          state
        end
      end

      defp validate_lexical_let_bindings(state, _kind, _declarations), do: state

      defp binding_contains_name?(%AST.Identifier{name: name}, name), do: true

      defp binding_contains_name?(%AST.ArrayPattern{elements: elements}, name),
        do: Enum.any?(elements, &binding_contains_name?(&1, name))

      defp binding_contains_name?(%AST.ObjectPattern{properties: properties}, name),
        do: Enum.any?(properties, &binding_contains_name?(&1, name))

      defp binding_contains_name?(%AST.Property{value: value}, name),
        do: binding_contains_name?(value, name)

      defp binding_contains_name?(%AST.RestElement{argument: argument}, name),
        do: binding_contains_name?(argument, name)

      defp binding_contains_name?(_binding, _name), do: false

      defp parse_using_declaration(state, await?) do
        state = if await?, do: advance(state), else: state
        state = expect_identifier_value(state, "using")
        {declarations, state} = parse_declarators(state, [])
        state = validate_using_initializers(state, declarations)
        state = consume_semicolon(state)
        kind = if await?, do: :await_using, else: :using
        {%AST.VariableDeclaration{kind: kind, declarations: declarations}, state}
      end

      defp validate_using_initializers(state, declarations) do
        if Enum.any?(declarations, &is_nil(&1.init)),
          do: add_error(state, current(state), "missing initializer in using declaration"),
          else: state
      end

      defp using_after_await?(state) do
        peek(state).type == :identifier and peek(state).value == "using" and
          peek_value(state, 2) != "[" and not peek(state).before_line_terminator? and
          not peek(state, 2).before_line_terminator?
      end

      defp for_let_declaration_start?(state) do
        peek_value(state) in ["[", "{"] or identifier_like?(peek(state))
      end

      defp parse_declarators(state, acc, allow_in? \\ true) do
        {id, state} = parse_binding_pattern(state)

        {init, state} =
          if match_value?(state, "=") do
            state = advance(state)

            if allow_in?,
              do: parse_expression(state, 2),
              else: parse_expression_no_in(state, 2)
          else
            {nil, state}
          end

        declarator = %AST.VariableDeclarator{id: id, init: init}

        if match_value?(state, ",") do
          parse_declarators(advance(state), [declarator | acc], allow_in?)
        else
          {Enum.reverse([declarator | acc]), state}
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

      defp parse_throw_statement(state) do
        state = advance(state)

        cond do
          eof?(state) or statement_end?(state) ->
            {%AST.ThrowStatement{},
             add_error(state, current(state), "expected expression after throw")}

          current(state).before_line_terminator? ->
            {%AST.ThrowStatement{},
             add_error(state, current(state), "line terminator after throw")}

          true ->
            {argument, state} = parse_expression(state, 0)
            {%AST.ThrowStatement{argument: argument}, consume_semicolon(state)}
        end
      end

      defp parse_break_statement(state) do
        state = advance(state)

        {label, state} =
          if not eof?(state) and not current(state).before_line_terminator? and
               identifier_like?(current(state)) do
            parse_binding_identifier(state)
          else
            {nil, state}
          end

        {%AST.BreakStatement{label: label}, consume_semicolon(state)}
      end

      defp parse_continue_statement(state) do
        state = advance(state)

        {label, state} =
          if not eof?(state) and not current(state).before_line_terminator? and
               identifier_like?(current(state)) do
            parse_binding_identifier(state)
          else
            {nil, state}
          end

        {%AST.ContinueStatement{label: label}, consume_semicolon(state)}
      end

      defp parse_if_statement(state) do
        state = advance(state)
        {test, state} = parse_parenthesized_expression(state)
        {consequent, state} = parse_statement(state)
        state = validate_if_single_statement_body(state, consequent)

        {alternate, state} =
          if keyword?(state, "else") do
            {alternate, state} = parse_statement(advance(state))
            {alternate, validate_if_single_statement_body(state, alternate)}
          else
            {nil, state}
          end

        {%AST.IfStatement{test: test, consequent: consequent, alternate: alternate}, state}
      end

      defp parse_while_statement(state) do
        state = advance(state)
        {test, state} = parse_parenthesized_expression(state)
        {body, state} = parse_statement(state)
        state = validate_single_statement_body(state, body)
        {%AST.WhileStatement{test: test, body: body}, state}
      end

      defp parse_for_statement(state, await?) do
        state = advance(state)

        {await?, state} =
          if keyword?(state, "await") do
            {true, advance(state)}
          else
            {await?, state}
          end

        state = expect_value(state, "(")

        cond do
          match_value?(state, ";") ->
            parse_classic_for_tail(state, nil)

          keyword?(state, "await") and using_after_await?(state) ->
            state = advance(state)
            state = expect_identifier_value(state, "using")
            {declarations, state} = parse_declarators(state, [], false)
            init = %AST.VariableDeclaration{kind: :await_using, declarations: declarations}
            parse_for_after_init(state, init, true)

          keyword?(state, "let") and state.source_type == :script and
              not for_let_declaration_start?(state) ->
            {init, state} = parse_expression_no_in(state, 0)
            parse_for_after_init(state, init, await?)

          keyword?(state, "var") or keyword?(state, "let") or keyword?(state, "const") ->
            {kind, state} = consume_keyword_value(state)
            {declarations, state} = parse_declarators(state, [], false)
            state = validate_lexical_let_bindings(state, kind, declarations)

            init = %AST.VariableDeclaration{
              kind: String.to_atom(kind),
              declarations: declarations
            }

            parse_for_after_init(state, init, await?)

          current(state).type == :identifier and current(state).value == "using" ->
            state = advance(state)
            {declarations, state} = parse_declarators(state, [], false)
            kind = if await?, do: :await_using, else: :using
            init = %AST.VariableDeclaration{kind: kind, declarations: declarations}
            parse_for_after_init(state, init, await?)

          identifier_like?(current(state)) and peek_value(state) in ["in", "of"] and
              peek_value(state, 2) != "=>" ->
            state = validate_raw_async_for_of_start(state, await?)
            {init, state} = parse_binding_identifier(state)
            parse_for_after_init(state, init, await?)

          true ->
            {init, state} = parse_expression_no_in(state, 0)
            parse_for_after_init(state, init, await?)
        end
      end

      defp parse_for_after_init(state, init, await?) do
        cond do
          keyword?(state, "in") ->
            state = validate_for_in_initializer(state, init)
            state = advance(state)
            {right, state} = parse_expression(state, 0)
            state = expect_value(state, ")")
            {body, state} = parse_statement(state)
            state = validate_single_statement_body(state, body)
            state = validate_for_head_lexical_bindings(state, init, body)
            {%AST.ForInStatement{left: init, right: right, body: body}, state}

          identifier_like?(current(state)) and current(state).value == "of" and
              current(state).raw == "of" ->
            state = validate_for_of_initializer(state, init)
            state = advance(state)
            {right, state} = parse_expression(state, 0)
            state = validate_for_of_right_expression(state, right)
            state = expect_value(state, ")")
            {body, state} = parse_statement(state)
            state = validate_single_statement_body(state, body)
            state = validate_for_head_lexical_bindings(state, init, body)
            {%AST.ForOfStatement{left: init, right: right, body: body, await: await?}, state}

          true ->
            parse_classic_for_tail(state, init)
        end
      end

      defp validate_rest_initializer(state) do
        if match_value?(state, "=") do
          add_error(state, current(state), "rest element cannot have initializer")
        else
          state
        end
      end

      defp validate_raw_async_for_of_start(state, false) do
        if current(state).raw == "async" and peek(state).raw == "of" do
          add_error(state, current(state), "invalid assignment target")
        else
          state
        end
      end

      defp validate_raw_async_for_of_start(state, _await?), do: state

      defp validate_for_of_initializer(state, init),
        do: validate_for_in_of_initializer(state, init)

      defp validate_for_of_right_expression(state, %AST.SequenceExpression{parenthesized?: false}),
           do: add_error(state, current(state), "expected )")

      defp validate_for_of_right_expression(state, _right), do: state

      defp validate_for_in_initializer(state, %AST.AssignmentExpression{}),
        do: add_error(state, current(state), "for-in/of declaration cannot have initializer")

      defp validate_for_in_initializer(state, %AST.VariableDeclaration{
             kind: :var,
             declarations: declarations
           }) do
        if Enum.any?(declarations, &for_in_var_pattern_initializer?/1) do
          add_error(state, current(state), "for-in/of declaration cannot have initializer")
        else
          state
        end
      end

      defp validate_for_in_initializer(state, init),
        do: validate_for_in_of_initializer(state, init)

      defp for_in_var_pattern_initializer?(%AST.VariableDeclarator{id: %AST.Identifier{}}),
        do: false

      defp for_in_var_pattern_initializer?(%AST.VariableDeclarator{init: nil}), do: false
      defp for_in_var_pattern_initializer?(%AST.VariableDeclarator{}), do: true

      defp validate_for_in_of_initializer(state, %AST.VariableDeclaration{
             declarations: declarations
           }) do
        cond do
          length(declarations) > 1 ->
            add_error(state, current(state), "expected 'of' or 'in' in for control expression")

          Enum.any?(declarations, & &1.init) ->
            add_error(state, current(state), "for-in/of declaration cannot have initializer")

          true ->
            state
        end
      end

      defp validate_for_in_of_initializer(state, %AST.ArrayExpression{} = init),
        do: validate_for_in_of_assignment_pattern(state, init)

      defp validate_for_in_of_initializer(state, %AST.ObjectExpression{} = init),
        do: validate_for_in_of_assignment_pattern(state, init)

      defp validate_for_in_of_initializer(state, %AST.Identifier{name: name})
           when name in ["this", "super"],
           do: add_error(state, current(state), "invalid assignment target")

      defp validate_for_in_of_initializer(state, %AST.SequenceExpression{}),
        do: add_error(state, current(state), "invalid assignment target")

      defp validate_for_in_of_initializer(state, _init), do: state

      defp validate_for_in_of_assignment_pattern(state, init) do
        if invalid_for_in_of_assignment_pattern?(init) do
          add_error(state, current(state), "invalid destructuring target")
        else
          state
        end
      end

      defp invalid_for_in_of_assignment_pattern?(%AST.ArrayExpression{elements: elements}),
        do:
          invalid_for_in_of_rest_position?(elements) or
            Enum.any?(elements, &invalid_for_in_of_assignment_pattern?/1)

      defp invalid_for_in_of_assignment_pattern?(%AST.ObjectExpression{properties: properties}),
        do:
          invalid_for_in_of_rest_position?(properties) or
            Enum.any?(properties, &invalid_for_in_of_assignment_pattern?/1)

      defp invalid_for_in_of_assignment_pattern?(%AST.Property{kind: kind})
           when kind in [:get, :set],
           do: true

      defp invalid_for_in_of_assignment_pattern?(%AST.Property{method: true}), do: true

      defp invalid_for_in_of_assignment_pattern?(%AST.Property{value: value}),
        do: invalid_for_in_of_assignment_pattern?(value)

      defp invalid_for_in_of_assignment_pattern?(%AST.SpreadElement{
             argument: %AST.AssignmentExpression{}
           }),
           do: true

      defp invalid_for_in_of_assignment_pattern?(%AST.SpreadElement{argument: argument}),
        do: invalid_for_in_of_assignment_pattern?(argument)

      defp invalid_for_in_of_assignment_pattern?(%AST.AssignmentExpression{left: left}),
        do: invalid_for_in_of_assignment_pattern?(left)

      defp invalid_for_in_of_assignment_pattern?(%AST.SequenceExpression{}), do: true
      defp invalid_for_in_of_assignment_pattern?(_target), do: false

      defp invalid_for_in_of_rest_position?(items) do
        last_index = length(items) - 1

        items
        |> Enum.with_index()
        |> Enum.any?(fn
          {%AST.SpreadElement{}, index} -> index != last_index
          {_item, _index} -> false
        end)
      end

      defp validate_for_head_lexical_bindings(
             state,
             %AST.VariableDeclaration{kind: kind, declarations: declarations},
             body
           )
           when kind in [:let, :const] do
        head_names = Enum.flat_map(declarations, &binding_names(&1.id))
        body_var_names = var_declared_names(body)

        cond do
          length(head_names) != length(Enum.uniq(head_names)) ->
            add_error(state, current(state), "duplicate lexical declaration")

          Enum.any?(head_names, &(&1 in body_var_names)) ->
            add_error(state, current(state), "lexical declaration conflicts with var declaration")

          true ->
            state
        end
      end

      defp validate_for_head_lexical_bindings(state, _init, _body), do: state

      defp var_declared_names(%AST.VariableDeclaration{kind: :var, declarations: declarations}),
        do: Enum.flat_map(declarations, &binding_names(&1.id))

      defp var_declared_names(%AST.BlockStatement{body: body}),
        do: Enum.flat_map(body, &var_declared_names/1)

      defp var_declared_names(_statement), do: []

      defp binding_names(%AST.Identifier{name: name}), do: [name]
      defp binding_names(%AST.AssignmentPattern{left: left}), do: binding_names(left)
      defp binding_names(%AST.RestElement{argument: argument}), do: binding_names(argument)

      defp binding_names(%AST.ArrayPattern{elements: elements}),
        do: Enum.flat_map(elements, &binding_names/1)

      defp binding_names(%AST.ObjectPattern{properties: properties}),
        do: Enum.flat_map(properties, &binding_names/1)

      defp binding_names(%AST.Property{value: value}), do: binding_names(value)
      defp binding_names(_binding), do: []

      defp parse_classic_for_tail(state, init) do
        state = expect_value(state, ";")

        {test, state} =
          if match_value?(state, ";") do
            {nil, state}
          else
            parse_expression(state, 0)
          end

        state = expect_value(state, ";")

        {update, state} =
          if match_value?(state, ")") do
            {nil, state}
          else
            parse_expression(state, 0)
          end

        state = expect_value(state, ")")
        {body, state} = parse_statement(state)
        state = validate_single_statement_body(state, body)
        state = validate_for_head_lexical_bindings(state, init, body)
        {%AST.ForStatement{init: init, test: test, update: update, body: body}, state}
      end

      defp parse_do_while_statement(state) do
        state = advance(state)
        {body, state} = parse_statement(state)
        state = validate_single_statement_body(state, body)
        state = expect_keyword(state, "while")
        {test, state} = parse_parenthesized_expression(state)
        {%AST.DoWhileStatement{body: body, test: test}, consume_optional_semicolon(state)}
      end

      defp validate_if_single_statement_body(state, %AST.FunctionDeclaration{
             async: false,
             generator: false
           }),
           do: state

      defp validate_if_single_statement_body(state, body),
        do: validate_single_statement_body(state, body)

      defp validate_single_statement_body(state, %AST.LabeledStatement{} = statement) do
        if labeled_function_declaration?(statement) do
          add_error(
            state,
            current(state),
            "function declarations can't appear in single-statement context"
          )
        else
          state
        end
      end

      defp labeled_function_declaration?(%AST.LabeledStatement{body: %AST.FunctionDeclaration{}}),
        do: true

      defp labeled_function_declaration?(%AST.LabeledStatement{body: body}),
        do: labeled_function_declaration?(body)

      defp labeled_function_declaration?(_statement), do: false

      defp validate_single_statement_body(state, %AST.FunctionDeclaration{}),
        do:
          add_error(
            state,
            current(state),
            "function declarations can't appear in single-statement context"
          )

      defp validate_single_statement_body(state, %AST.ClassDeclaration{}),
        do:
          add_error(
            state,
            current(state),
            "class declarations can't appear in single-statement context"
          )

      defp validate_single_statement_body(state, %AST.VariableDeclaration{kind: kind})
           when kind in [:let, :const] do
        add_error(
          state,
          current(state),
          "lexical declarations can't appear in single-statement context"
        )
      end

      defp validate_single_statement_body(state, _body), do: state

      defp parse_with_statement(state) do
        state = advance(state)
        {object, state} = parse_parenthesized_expression(state)
        {body, state} = parse_statement(state)
        state = validate_single_statement_body(state, body)
        {%AST.WithStatement{object: object, body: body}, state}
      end

      defp parse_labeled_statement(state) do
        {label, state} = parse_binding_identifier(state)
        state = expect_value(state, ":")
        {body, state} = parse_statement(state)
        state = validate_labeled_statement_body(state, body)
        {%AST.LabeledStatement{label: label, body: body}, state}
      end

      defp validate_labeled_statement_body(
             state,
             %AST.FunctionDeclaration{async: false, generator: false}
           ),
           do: state

      defp validate_labeled_statement_body(state, %AST.LabeledStatement{}), do: state

      defp validate_labeled_statement_body(state, body),
        do: validate_single_statement_body(state, body)

      defp parse_switch_statement(state) do
        state = advance(state)
        {discriminant, state} = parse_parenthesized_expression(state)
        state = expect_value(state, "{")
        {cases, state} = parse_switch_cases(state, [], false)
        state = validate_switch_bindings(state, cases)
        {%AST.SwitchStatement{discriminant: discriminant, cases: cases}, state}
      end

      defp validate_switch_bindings(state, cases) do
        statements = Enum.flat_map(cases, & &1.consequent)
        lexical_bindings = Enum.flat_map(statements, &switch_lexical_bindings/1)
        lexical_names = Enum.map(lexical_bindings, &elem(&1, 0))
        var_names = Enum.flat_map(statements, &switch_var_names/1)

        cond do
          invalid_switch_duplicate_lexical_bindings?(lexical_bindings) ->
            add_error(state, current(state), "duplicate lexical declaration")

          Enum.any?(var_names, &(&1 in lexical_names)) ->
            add_error(state, current(state), "lexical declaration conflicts with var declaration")

          true ->
            state
        end
      end

      defp invalid_switch_duplicate_lexical_bindings?(bindings) do
        bindings
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.any?(fn {_name, kinds} ->
          length(kinds) > 1 and Enum.any?(kinds, &(&1 != :function))
        end)
      end

      defp switch_lexical_bindings(%AST.VariableDeclaration{
             kind: kind,
             declarations: declarations
           })
           when kind in [:let, :const],
           do: Enum.map(Enum.flat_map(declarations, &binding_names(&1.id)), &{&1, :lexical})

      defp switch_lexical_bindings(%AST.ClassDeclaration{id: %AST.Identifier{name: name}}),
        do: [{name, :lexical}]

      defp switch_lexical_bindings(%AST.FunctionDeclaration{
             id: %AST.Identifier{name: name},
             async: false,
             generator: false
           }),
           do: [{name, :function}]

      defp switch_lexical_bindings(%AST.FunctionDeclaration{id: %AST.Identifier{name: name}}),
        do: [{name, :lexical}]

      defp switch_lexical_bindings(_statement), do: []

      defp switch_var_names(%AST.VariableDeclaration{kind: :var, declarations: declarations}),
        do: Enum.flat_map(declarations, &binding_names(&1.id))

      defp switch_var_names(_statement), do: []

      defp parse_switch_cases(state, acc, default_seen?) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc), add_error(state, current(state), "unterminated switch statement")}

          match_value?(state, "}") ->
            {Enum.reverse(acc), advance(state)}

          keyword?(state, "case") ->
            state = advance(state)
            {test, state} = parse_expression(state, 0)
            state = expect_value(state, ":")
            {consequent, state} = parse_switch_consequent(state, [])

            parse_switch_cases(
              state,
              [%AST.SwitchCase{test: test, consequent: consequent} | acc],
              default_seen?
            )

          keyword?(state, "default") ->
            state = advance(state)

            state =
              if default_seen?,
                do: add_error(state, current(state), "duplicate default clause"),
                else: state

            state = expect_value(state, ":")
            {consequent, state} = parse_switch_consequent(state, [])

            parse_switch_cases(
              state,
              [%AST.SwitchCase{test: nil, consequent: consequent} | acc],
              true
            )

          true ->
            state = add_error(state, current(state), "invalid switch statement")
            {statement, state} = parse_statement(state)

            parse_switch_cases(
              state,
              [%AST.SwitchCase{test: nil, consequent: [statement]} | acc],
              default_seen?
            )
        end
      end

      defp parse_switch_consequent(state, acc) do
        if eof?(state) or match_value?(state, "}") or keyword?(state, "case") or
             keyword?(state, "default") do
          {Enum.reverse(acc), state}
        else
          {statement, state} = parse_statement(state)
          parse_switch_consequent(state, [statement | acc])
        end
      end

      defp parse_try_statement(state) do
        state = advance(state)
        {block, state} = parse_block_statement(state)

        {handler, state} =
          if keyword?(state, "catch") do
            parse_catch_clause(state)
          else
            {nil, state}
          end

        {finalizer, state} =
          if keyword?(state, "finally") do
            parse_block_statement(advance(state))
          else
            {nil, state}
          end

        if handler == nil and finalizer == nil do
          {%AST.TryStatement{block: block},
           add_error(state, current(state), "expected catch or finally")}
        else
          {%AST.TryStatement{block: block, handler: handler, finalizer: finalizer}, state}
        end
      end

      defp parse_catch_clause(state) do
        state = advance(state)

        {param, state} =
          if match_value?(state, "(") do
            state = advance(state)
            {param, state} = parse_binding_pattern(state)
            {param, expect_value(state, ")")}
          else
            {nil, state}
          end

        {body, state} = parse_block_statement(state)
        state = Validation.validate_catch_param_bindings(state, param, body)
        {%AST.CatchClause{param: param, body: body}, state}
      end

      defp parse_function_declaration(state, require_name? \\ true) do
        {async?, state} = consume_async_modifier(state)
        state = expect_keyword(state, "function")
        {generator?, state} = consume_generator_marker(state)

        {id, state} =
          cond do
            identifier_like?(current(state)) ->
              parse_binding_identifier(state)

            require_name? ->
              {%AST.Identifier{name: ""},
               add_error(state, current(state), "expected binding identifier")}

            true ->
              {nil, state}
          end

        {params, state} = parse_function_formal_parameters(state, generator?, async?)
        {body, state} = parse_function_body(state, generator?, async?)

        state =
          state
          |> Validation.validate_super_params(params)
          |> Validation.validate_async_function_name(async?, id)
          |> Validation.validate_async_generator_function_name(async? and generator?, id)
          |> Validation.validate_async_params(async?, params)
          |> Validation.validate_async_body_bindings(async?, body)
          |> Validation.validate_generator_params(generator?, params)
          |> Validation.validate_generator_body_bindings(generator?, body)
          |> Validation.validate_strict_function_name(id, body)
          |> Validation.validate_strict_function_params(params, body)

        {%AST.FunctionDeclaration{
           id: id,
           params: params,
           body: body,
           async: async?,
           generator: generator?
         }, state}
      end
    end
  end
end
