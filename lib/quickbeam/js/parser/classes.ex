defmodule QuickBEAM.JS.Parser.Classes do
  @moduledoc "Class declaration, expression, and element grammar for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp parse_class_declaration(state, require_name? \\ true) do
        {id, super_class, body, state} = parse_class_tail(advance(state), require_name?)
        {%AST.ClassDeclaration{id: id, super_class: super_class, body: body}, state}
      end

      defp parse_class_expression(state) do
        {id, super_class, body, state} = parse_class_tail(advance(state), false)
        {%AST.ClassExpression{id: id, super_class: super_class, body: body}, state}
      end

      defp parse_class_tail(state, require_name?) do
        {id, state} =
          cond do
            identifier_like?(current(state)) ->
              parse_binding_identifier(state)

            require_name? ->
              {%AST.Identifier{name: ""}, add_error(state, current(state), "expected class name")}

            true ->
              {nil, state}
          end

        {super_class, state} =
          if keyword?(state, "extends") do
            state = advance(state)
            parse_expression(state, 0)
          else
            {nil, state}
          end

        state = expect_value(state, "{")
        {body, state} = parse_class_elements(state, [])
        state = validate_duplicate_constructors(state, body)
        {id, super_class, body, state}
      end

      defp validate_duplicate_constructors(state, body),
        do: Validation.validate_duplicate_constructors(state, body)

      defp parse_class_elements(state, acc) do
        cond do
          eof?(state) ->
            {Enum.reverse(acc), add_error(state, current(state), "unterminated class body")}

          match_value?(state, "}") ->
            {Enum.reverse(acc), advance(state)}

          match_value?(state, ";") ->
            parse_class_elements(advance(state), acc)

          true ->
            {element, state} = parse_class_element(state)
            parse_class_elements(state, [element | acc])
        end
      end

      defp parse_class_element(state) do
        {static?, state} = consume_class_static_modifier(state)

        cond do
          static? and match_value?(state, "{") ->
            {block, state} = parse_block_statement(state)
            state = validate_strict_body_bindings(state, block)
            {%AST.StaticBlock{body: block.body}, state}

          async_method_start?(state) ->
            parse_async_class_method(state, static?)

          match_value?(state, "*") ->
            parse_generator_class_method(state, static?)

          match_value?(state, ["get", "set"]) and accessor_key_start?(state) ->
            parse_class_accessor(state, static?)

          true ->
            {key, computed?, state} = parse_class_key_with_computed(state)

            if match_value?(state, "(") do
              {params, state} = parse_formal_parameters(state)
              {body, state} = parse_function_body(state, false, false)

              state =
                state |> validate_strict_params(params) |> validate_strict_body_bindings(body)

              value = %AST.FunctionExpression{
                id: property_function_name(key),
                params: params,
                body: body
              }

              {%AST.MethodDefinition{
                 key: key,
                 value: value,
                 kind: class_method_kind(key, static?),
                 static: static?,
                 computed: computed?
               }, state}
            else
              {value, state} =
                if match_value?(state, "=") do
                  state = advance(state)
                  parse_expression(state, 0)
                else
                  {nil, state}
                end

              {%AST.FieldDefinition{key: key, value: value, static: static?, computed: computed?},
               consume_semicolon(state)}
            end
        end
      end

      defp parse_generator_class_method(state, static?) do
        state = advance(state)
        {key, computed?, state} = parse_class_key_with_computed(state)
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, true, false)

        state =
          state
          |> validate_generator_params(true, params)
          |> validate_strict_params(params)
          |> validate_strict_body_bindings(body)

        value = %AST.FunctionExpression{
          id: property_function_name(key),
          params: params,
          body: body,
          generator: true
        }

        {%AST.MethodDefinition{
           key: key,
           value: value,
           static: static?,
           computed: computed?
         }, state}
      end

      defp parse_async_class_method(state, static?) do
        state = advance(state)
        {generator?, state} = consume_generator_marker(state)
        {key, computed?, state} = parse_class_key_with_computed(state)
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_function_body(state, generator?, true)

        state =
          state
          |> validate_async_params(true, params)
          |> validate_generator_params(generator?, params)
          |> validate_strict_params(params)
          |> validate_strict_body_bindings(body)

        value = %AST.FunctionExpression{
          id: property_function_name(key),
          params: params,
          body: body,
          async: true,
          generator: generator?
        }

        {%AST.MethodDefinition{
           key: key,
           value: value,
           static: static?,
           computed: computed?
         }, state}
      end

      defp parse_class_accessor(state, static?) do
        kind = current(state).value |> String.to_atom()
        state = advance(state)
        {key, computed?, state} = parse_class_key_with_computed(state)
        {params, state} = parse_formal_parameters(state)
        {body, state} = parse_block_statement(state)
        state = state |> validate_strict_params(params) |> validate_strict_body_bindings(body)

        value = %AST.FunctionExpression{
          id: property_function_name(key),
          params: params,
          body: body
        }

        {%AST.MethodDefinition{
           key: key,
           value: value,
           kind: kind,
           static: static?,
           computed: computed?
         }, state}
      end

      defp class_method_kind(%AST.Identifier{name: "constructor"}, false), do: :constructor
      defp class_method_kind(_key, _static?), do: :method

      defp consume_class_static_modifier(state) do
        if match_value?(state, "static") and peek_value(state) not in ["(", ";", "="] do
          {true, advance(state)}
        else
          {false, state}
        end
      end

      defp parse_class_key_with_computed(state) do
        cond do
          match_value?(state, "#") ->
            state = advance(state)
            token = current(state)

            if identifier_like?(token) do
              {%AST.PrivateIdentifier{name: token.value}, false, advance(state)}
            else
              {%AST.PrivateIdentifier{name: ""}, false,
               add_error(state, token, "expected private name")}
            end

          true ->
            parse_property_key_with_computed(state)
        end
      end
    end
  end
end
