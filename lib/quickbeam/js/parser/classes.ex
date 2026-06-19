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

        state = validate_class_binding_identifier(state, id)

        {super_class, state} =
          if keyword?(state, "extends") do
            state = advance(state)
            parse_expression(state, 0)
          else
            {nil, state}
          end

        state = validate_class_heritage(state, super_class)
        state = expect_value(state, "{")
        {body, state} = parse_class_elements(state, [])

        state =
          state
          |> Validation.validate_duplicate_constructors(body)
          |> Validation.validate_class_element_names(body)

        {id, super_class, body, state}
      end

      defp validate_class_heritage(state, %AST.ArrowFunctionExpression{parenthesized?: false}),
        do: add_error(state, current(state), "invalid class heritage")

      defp validate_class_heritage(state, _super_class), do: state

      defp validate_class_binding_identifier(state, %AST.Identifier{name: name})
           when name in ["let", "static", "yield"] do
        add_error(state, current(state), "expected class name")
      end

      defp validate_class_binding_identifier(%{await_allowed?: true} = state, %AST.Identifier{
             name: "await"
           }) do
        add_error(state, current(state), "expected class name")
      end

      defp validate_class_binding_identifier(state, _id), do: state

      defp parse_class_formal_parameters(state, await_allowed?) do
        previous_await_allowed? = state.await_allowed?
        {params, state} = parse_formal_parameters(%{state | await_allowed?: await_allowed?})
        {params, %{state | await_allowed?: previous_await_allowed?}}
      end

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
        state = consume_class_element_decorators(state)
        {static?, state} = consume_class_static_modifier(state)

        cond do
          static? and match_value?(state, "{") ->
            {block, state} = parse_static_block_statement(state)
            state = Validation.validate_strict_body_bindings(state, block)
            {%AST.StaticBlock{body: block.body}, state}

          async_method_start?(state) ->
            parse_async_class_method(state, static?)

          match_value?(state, "*") ->
            parse_generator_class_method(state, static?)

          match_value?(state, ["get", "set"]) and accessor_key_start?(state) ->
            parse_class_accessor(state, static?)

          match_value?(state, "accessor") and auto_accessor_field_start?(state) ->
            parse_auto_accessor_field(state, static?)

          true ->
            {key, computed?, state} = parse_class_key_with_computed(state)

            if match_value?(state, "(") do
              {params, state} = parse_class_formal_parameters(state, false)
              {body, state} = parse_function_body(state, false, false)

              state =
                state
                |> Validation.validate_super_params(params)
                |> Validation.validate_generator_params(true, params)
                |> Validation.validate_strict_params(params)
                |> Validation.validate_strict_function_params(params, body)
                |> Validation.validate_strict_body_bindings(body)

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
              {value, state} = parse_class_field_initializer(state)

              {%AST.FieldDefinition{key: key, value: value, static: static?, computed: computed?},
               consume_semicolon(state)}
            end
        end
      end

      defp parse_generator_class_method(state, static?) do
        state = advance(state)
        {key, computed?, state} = parse_class_key_with_computed(state)
        {params, state} = parse_class_formal_parameters(state, false)
        {body, state} = parse_function_body(state, true, false)

        state =
          state
          |> Validation.validate_super_params(params)
          |> Validation.validate_generator_params(true, params)
          |> Validation.validate_generator_body_bindings(true, body)
          |> Validation.validate_strict_params(params)
          |> Validation.validate_strict_function_params(params, body)
          |> Validation.validate_strict_body_bindings(body)

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
        {params, state} = parse_class_formal_parameters(state, true)
        {body, state} = parse_function_body(state, generator?, true)

        state =
          state
          |> validate_class_method_super_call_params(params)
          |> Validation.validate_async_function_name(true, property_function_name(key))
          |> Validation.validate_async_generator_function_name(
            generator?,
            property_function_name(key)
          )
          |> Validation.validate_async_params(true, params)
          |> Validation.validate_async_body_bindings(true, body)
          |> Validation.validate_generator_params(true, params)
          |> Validation.validate_generator_body_bindings(generator?, body)
          |> Validation.validate_strict_params(params)
          |> Validation.validate_strict_function_params(params, body)
          |> Validation.validate_strict_body_bindings(body)

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

      defp validate_class_method_super_call_params(state, params) do
        if Enum.any?(params, &class_method_super_call_param?/1) do
          add_error(state, current(state), "super not allowed outside class method")
        else
          state
        end
      end

      defp class_method_super_call_param?(%AST.AssignmentPattern{right: right}),
        do: class_method_super_call_param?(right)

      defp class_method_super_call_param?(%AST.CallExpression{
             callee: %AST.Identifier{name: "super"}
           }),
           do: true

      defp class_method_super_call_param?(%AST.CallExpression{arguments: arguments}),
        do: Enum.any?(arguments, &class_method_super_call_param?/1)

      defp class_method_super_call_param?(_param), do: false

      defp parse_static_block_statement(state) do
        previous_await_allowed? = state.await_allowed?
        previous_yield_allowed? = state.yield_allowed?

        {block, state} =
          parse_block_statement(%{state | await_allowed?: true, yield_allowed?: false})

        state = validate_static_block_contents(state, block)

        {block,
         %{
           state
           | await_allowed?: previous_await_allowed?,
             yield_allowed?: previous_yield_allowed?
         }}
      end

      defp validate_static_block_contents(state, %AST.BlockStatement{body: body}) do
        cond do
          Enum.any?(body, &static_block_return_statement?/1) ->
            add_error(state, current(state), "return statement outside function")

          Enum.any?(body, &static_block_forbidden_identifier_statement?/1) ->
            add_error(state, current(state), "identifier not allowed in class static block")

          true ->
            state
        end
      end

      defp static_block_return_statement?(%AST.ReturnStatement{}), do: true

      defp static_block_return_statement?(%AST.BlockStatement{body: body}),
        do: Enum.any?(body, &static_block_return_statement?/1)

      defp static_block_return_statement?(_statement), do: false

      defp static_block_forbidden_identifier_statement?(%AST.ExpressionStatement{
             expression: expression
           }),
           do: static_block_forbidden_identifier_expression?(expression)

      defp static_block_forbidden_identifier_statement?(%AST.BlockStatement{body: body}),
        do: Enum.any?(body, &static_block_forbidden_identifier_statement?/1)

      defp static_block_forbidden_identifier_statement?(%AST.VariableDeclaration{
             declarations: declarations
           }) do
        Enum.any?(declarations, fn declaration ->
          static_block_forbidden_binding?(declaration.id) or
            static_block_forbidden_identifier_expression?(declaration.init)
        end)
      end

      defp static_block_forbidden_identifier_statement?(%AST.FunctionDeclaration{id: id}),
        do: static_block_forbidden_binding?(id)

      defp static_block_forbidden_identifier_statement?(%AST.LabeledStatement{label: label}),
        do: static_block_forbidden_binding?(label)

      defp static_block_forbidden_identifier_statement?(%AST.TryStatement{handler: handler}),
        do: static_block_forbidden_catch?(handler)

      defp static_block_forbidden_catch?(%AST.CatchClause{param: param}),
        do: static_block_forbidden_binding?(param)

      defp static_block_forbidden_catch?(_handler), do: false

      defp static_block_forbidden_binding?(%AST.Identifier{name: name})
           when name in ["await", "arguments", "yield"],
           do: true

      defp static_block_forbidden_binding?(%AST.ArrayPattern{elements: elements}),
        do: Enum.any?(elements, &static_block_forbidden_binding?/1)

      defp static_block_forbidden_binding?(%AST.ObjectPattern{properties: properties}),
        do: Enum.any?(properties, &static_block_forbidden_binding?/1)

      defp static_block_forbidden_binding?(%AST.Property{value: value}),
        do: static_block_forbidden_binding?(value)

      defp static_block_forbidden_binding?(%AST.RestElement{argument: argument}),
        do: static_block_forbidden_binding?(argument)

      defp static_block_forbidden_binding?(_binding), do: false

      defp static_block_forbidden_identifier_statement?(_statement), do: false

      defp static_block_forbidden_identifier_expression?(%AST.Identifier{name: name})
           when name in ["arguments", "yield"],
           do: true

      defp static_block_forbidden_identifier_expression?(%AST.AwaitExpression{}), do: true
      defp static_block_forbidden_identifier_expression?(%AST.YieldExpression{}), do: true
      defp static_block_forbidden_identifier_expression?(%AST.FunctionExpression{}), do: false

      defp static_block_forbidden_identifier_expression?(%AST.ArrowFunctionExpression{}),
        do: false

      defp static_block_forbidden_identifier_expression?(%AST.ClassExpression{
             super_class: super_class,
             body: body
           }) do
        static_block_forbidden_identifier_expression?(super_class) or
          Enum.any?(body, &static_block_forbidden_identifier_class_element?/1)
      end

      defp static_block_forbidden_identifier_expression?(%AST.CallExpression{
             callee: callee,
             arguments: arguments
           }),
           do:
             static_block_forbidden_identifier_expression?(callee) or
               Enum.any?(arguments, &static_block_forbidden_identifier_expression?/1)

      defp static_block_forbidden_identifier_expression?(%AST.MemberExpression{
             object: object,
             property: property
           }),
           do:
             static_block_forbidden_identifier_expression?(object) or
               static_block_forbidden_identifier_expression?(property)

      defp static_block_forbidden_identifier_expression?(_expression), do: false

      defp static_block_forbidden_identifier_class_element?(%AST.MethodDefinition{
             computed: true,
             key: key
           }),
           do: static_block_forbidden_identifier_expression?(key)

      defp static_block_forbidden_identifier_class_element?(%AST.FieldDefinition{
             computed: true,
             key: key,
             value: value
           }),
           do:
             static_block_forbidden_identifier_expression?(key) or
               static_block_forbidden_identifier_expression?(value)

      defp static_block_forbidden_identifier_class_element?(%AST.FieldDefinition{value: value}),
        do: static_block_forbidden_identifier_expression?(value)

      defp static_block_forbidden_identifier_class_element?(%AST.StaticBlock{body: body}),
        do: Enum.any?(body, &static_block_forbidden_identifier_statement?/1)

      defp static_block_forbidden_identifier_class_element?(_element), do: false

      defp parse_auto_accessor_field(state, static?) do
        state = advance(state)
        {key, computed?, state} = parse_class_key_with_computed(state)
        {value, state} = parse_class_field_initializer(state)

        {%AST.FieldDefinition{key: key, value: value, static: static?, computed: computed?},
         consume_semicolon(state)}
      end

      defp parse_class_accessor(state, static?) do
        kind = current(state).value |> String.to_atom()
        state = advance(state)
        {key, computed?, state} = parse_class_key_with_computed(state)
        {params, state} = parse_class_formal_parameters(state, false)
        {body, state} = parse_block_statement(state)

        state =
          state
          |> validate_class_accessor_arity(kind, params)
          |> Validation.validate_super_params(params)
          |> Validation.validate_generator_params(true, params)
          |> Validation.validate_strict_params(params)
          |> Validation.validate_strict_function_params(params, body)
          |> Validation.validate_strict_body_bindings(body)

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

      defp validate_class_accessor_arity(state, :get, [_ | _]),
        do: add_error(state, current(state), "invalid number of arguments for getter or setter")

      defp validate_class_accessor_arity(state, :set, params) when length(params) != 1,
        do: add_error(state, current(state), "invalid number of arguments for getter or setter")

      defp validate_class_accessor_arity(state, _kind, _params), do: state

      defp parse_class_field_initializer(state) do
        if match_value?(state, "=") do
          state = advance(state)
          previous_await_allowed? = state.await_allowed?
          previous_yield_allowed? = state.yield_allowed?

          {value, state} =
            parse_expression(%{state | await_allowed?: false, yield_allowed?: false}, 0)

          {value,
           %{
             state
             | await_allowed?: previous_await_allowed?,
               yield_allowed?: previous_yield_allowed?
           }}
        else
          {nil, state}
        end
      end

      defp class_method_kind(%AST.Identifier{name: "constructor"}, false), do: :constructor
      defp class_method_kind(_key, _static?), do: :method

      defp consume_class_element_decorators(state) do
        if match_value?(state, "@") do
          state = advance(state)
          {_decorator, state} = parse_expression(state, 0)
          consume_class_element_decorators(state)
        else
          state
        end
      end

      defp consume_class_static_modifier(state) do
        if raw_keyword?(current(state), "static") and peek_value(state) not in ["(", ";", "="] do
          {true, advance(state)}
        else
          {false, state}
        end
      end

      defp auto_accessor_field_start?(state) do
        not peek(state).before_line_terminator? and peek_value(state) not in ["(", ";", "="] and
          (identifier_like?(peek(state)) or
             peek(state).type in [:string, :number, :boolean, :null] or
             peek_value(state) in ["#", "["])
      end

      defp parse_class_key_with_computed(state) do
        if match_value?(state, "#") do
          hash = current(state)
          state = advance(state)
          token = current(state)

          if private_identifier_token?(hash, token) do
            {%AST.PrivateIdentifier{name: token.value}, false, advance(state)}
          else
            {%AST.PrivateIdentifier{name: ""}, false,
             add_error(state, token, "expected private name")}
          end
        else
          parse_property_key_with_computed(state)
        end
      end
    end
  end
end
