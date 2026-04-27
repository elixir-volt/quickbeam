defmodule QuickBEAM.JS.Parser.ValidationDelegates do
  @moduledoc "Private validation delegate functions used by parser grammar clauses."

  defmacro __using__(_opts) do
    quote do
      alias QuickBEAM.JS.Parser.AST
      alias QuickBEAM.JS.Parser.{Error, Lexer, Token, Validation}

      defp validate_module_declarations(state, body),
        do: Validation.validate_module_declarations(state, body)

      defp validate_nested_module_declarations(state, body),
        do: Validation.validate_nested_module_declarations(state, body)

      defp validate_duplicate_proto_initializers(state, body),
        do: Validation.validate_duplicate_proto_initializers(state, body)

      defp validate_yield_context(state, body), do: Validation.validate_yield_context(state, body)
      defp validate_await_context(state, body), do: Validation.validate_await_context(state, body)

      defp validate_new_target_context(state, body),
        do: Validation.validate_new_target_context(state, body)

      defp validate_import_meta_context(state, body),
        do: Validation.validate_import_meta_context(state, body)

      defp validate_super_context(state, body), do: Validation.validate_super_context(state, body)

      defp validate_class_super_calls(state, body),
        do: Validation.validate_class_super_calls(state, body)

      defp validate_duplicate_private_names(state, body),
        do: Validation.validate_duplicate_private_names(state, body)

      defp validate_declared_private_names(state, body),
        do: Validation.validate_declared_private_names(state, body)

      defp validate_duplicate_lexical_bindings(state, body),
        do: Validation.validate_duplicate_lexical_bindings(state, body)

      defp validate_control_flow(state, body), do: Validation.validate_control_flow(state, body)

      defp validate_async_params(state, async?, params),
        do: Validation.validate_async_params(state, async?, params)

      defp validate_generator_params(state, generator?, params),
        do: Validation.validate_generator_params(state, generator?, params)

      defp validate_strict_function_name(state, id, body),
        do: Validation.validate_strict_function_name(state, id, body)

      defp validate_strict_program_bindings(state, body),
        do: Validation.validate_strict_program_bindings(state, body)

      defp validate_arrow_params(state, params, body),
        do: Validation.validate_arrow_params(state, params, body)

      defp validate_strict_function_params(state, params, body),
        do: Validation.validate_strict_function_params(state, params, body)

      defp validate_strict_params(state, params),
        do: Validation.validate_strict_params(state, params)

      defp validate_strict_body_bindings(state, body),
        do: Validation.validate_strict_body_bindings(state, body)
    end
  end
end
