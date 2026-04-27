defmodule QuickBEAM.JS.Parser.Modules do
  @moduledoc "Import and export grammar for the experimental JavaScript parser."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp parse_import_declaration(state) do
        state = advance(state)

        cond do
          current(state).type == :string ->
            source = %AST.Literal{value: current(state).value, raw: current(state).raw}
            {attributes, state} = parse_import_attributes(advance(state))

            {%AST.ImportDeclaration{source: source, attributes: attributes},
             consume_semicolon(state)}

          true ->
            state = consume_import_phase_modifier(state)
            state = consume_import_defer_modifier(state)
            {specifiers, state} = parse_import_specifiers(state, [])
            state = expect_identifier_value(state, "from")
            {source, state} = parse_module_source(state)
            {attributes, state} = parse_import_attributes(state)

            {%AST.ImportDeclaration{
               specifiers: specifiers,
               source: source,
               attributes: attributes
             }, consume_semicolon(state)}
        end
      end

      defp consume_import_phase_modifier(state) do
        if current(state).value == "source" and
             (peek_value(state) != "from" or peek_value(state, 2) == "from") do
          advance(state)
        else
          state
        end
      end

      defp consume_import_defer_modifier(state) do
        if current(state).value == "defer" and peek_value(state) == "*" do
          advance(state)
        else
          state
        end
      end

      defp parse_import_attributes(state) do
        if match_value?(state, ["assert", "with"]) and peek_value(state) == "{" do
          state = advance(state)
          parse_object_expression(state)
        else
          {nil, state}
        end
      end

      defp parse_import_specifiers(state, acc) do
        cond do
          current(state).type == :identifier and acc == [] ->
            spec = %AST.ImportDefaultSpecifier{local: %AST.Identifier{name: current(state).value}}
            state = advance(state)

            if match_value?(state, ",") do
              state = advance(state)

              if identifier_like?(current(state)) and current(state).value == "from" do
                {Enum.reverse([spec | acc]),
                 add_error(state, current(state), "expected import specifier")}
              else
                parse_import_specifiers(state, [spec | acc])
              end
            else
              {Enum.reverse([spec | acc]), state}
            end

          match_value?(state, "*") ->
            state = advance(state)
            state = expect_identifier_value(state, "as")
            {local, state} = parse_binding_identifier(state)
            {Enum.reverse([%AST.ImportNamespaceSpecifier{local: local} | acc]), state}

          match_value?(state, "{") ->
            {named, state} = parse_named_import_specifiers(advance(state), [])
            {Enum.reverse(acc) ++ named, state}

          true ->
            {Enum.reverse(acc), state}
        end
      end

      defp parse_named_import_specifiers(state, acc) do
        cond do
          match_value?(state, "}") ->
            {Enum.reverse(acc), advance(state)}

          true ->
            {imported, state} = parse_property_key(state)

            {local, state} =
              if identifier_like?(current(state)) and current(state).value == "as" do
                parse_binding_identifier(advance(state))
              else
                {imported, state}
              end

            spec = %AST.ImportSpecifier{imported: imported, local: local}

            cond do
              match_value?(state, ",") ->
                parse_named_import_specifiers(advance(state), [spec | acc])

              match_value?(state, "}") ->
                {Enum.reverse([spec | acc]), advance(state)}

              true ->
                {Enum.reverse([spec | acc]), expect_value(state, "}")}
            end
        end
      end

      defp parse_export_declaration(state) do
        state = advance(state)

        cond do
          keyword?(state, "default") ->
            parse_export_default_declaration(advance(state))

          match_value?(state, "*") ->
            parse_export_all_declaration(advance(state))

          keyword?(state, "var") or keyword?(state, "let") or keyword?(state, "const") ->
            {declaration, state} = parse_variable_declaration(state)
            {%AST.ExportNamedDeclaration{declaration: declaration}, state}

          function_start?(state) ->
            {declaration, state} = parse_function_declaration(state)
            {%AST.ExportNamedDeclaration{declaration: declaration}, state}

          keyword?(state, "class") ->
            {declaration, state} = parse_class_declaration(state)
            {%AST.ExportNamedDeclaration{declaration: declaration}, state}

          match_value?(state, "{") ->
            {specifiers, state} = parse_export_specifiers(advance(state), [])

            {source, state} =
              if identifier_like?(current(state)) and current(state).value == "from" do
                parse_module_source(advance(state))
              else
                {nil, state}
              end

            {attributes, state} =
              if source, do: parse_import_attributes(state), else: {nil, state}

            {%AST.ExportNamedDeclaration{
               specifiers: specifiers,
               source: source,
               attributes: attributes
             }, consume_semicolon(state)}

          true ->
            {%AST.ExportNamedDeclaration{},
             add_error(state, current(state), "expected export declaration")}
        end
      end

      defp parse_export_all_declaration(state) do
        {exported, state} =
          if identifier_like?(current(state)) and current(state).value == "as" do
            state = advance(state)
            parse_property_key(state)
          else
            {nil, state}
          end

        state = expect_identifier_value(state, "from")
        {source, state} = parse_module_source(state)
        {attributes, state} = parse_import_attributes(state)

        {%AST.ExportAllDeclaration{exported: exported, source: source, attributes: attributes},
         consume_semicolon(state)}
      end

      defp parse_export_default_declaration(state) do
        cond do
          function_start?(state) ->
            {declaration, state} = parse_function_declaration(state, false)
            {%AST.ExportDefaultDeclaration{declaration: declaration}, state}

          keyword?(state, "class") ->
            {declaration, state} = parse_class_declaration(state, false)
            {%AST.ExportDefaultDeclaration{declaration: declaration}, state}

          true ->
            {declaration, state} = parse_expression(state, 0)
            {%AST.ExportDefaultDeclaration{declaration: declaration}, consume_semicolon(state)}
        end
      end

      defp parse_export_specifiers(state, acc) do
        cond do
          match_value?(state, "}") ->
            {Enum.reverse(acc), advance(state)}

          true ->
            {local, state} = parse_property_key(state)

            {exported, state} =
              if identifier_like?(current(state)) and current(state).value == "as" do
                parse_property_key(advance(state))
              else
                {local, state}
              end

            spec = %AST.ExportSpecifier{local: local, exported: exported}

            cond do
              match_value?(state, ",") -> parse_export_specifiers(advance(state), [spec | acc])
              match_value?(state, "}") -> {Enum.reverse([spec | acc]), advance(state)}
              true -> {Enum.reverse([spec | acc]), expect_value(state, "}")}
            end
        end
      end

      defp parse_module_source(state) do
        if current(state).type == :string do
          {%AST.Literal{value: current(state).value, raw: current(state).raw}, advance(state)}
        else
          {%AST.Literal{value: "", raw: ""},
           add_error(state, current(state), "expected module source")}
        end
      end
    end
  end
end
