defmodule QuickBEAM.JS.Parser.Validation do
  @moduledoc "Facade for JavaScript parser validation passes."

  alias QuickBEAM.JS.Parser.Validation

  defdelegate validate_catch_param_bindings(state, param, body), to: Validation.Bindings
  defdelegate validate_duplicate_lexical_bindings(state, body), to: Validation.Bindings
  defdelegate validate_duplicate_block_bindings(state, body), to: Validation.Bindings
  defdelegate validate_restricted_global_lexical_bindings(state, body), to: Validation.Bindings
  defdelegate validate_control_flow(state, body), to: Validation.ControlFlow
  defdelegate validate_async_body_bindings(state, async?, body), to: Validation.Strict.Params
  defdelegate validate_async_function_name(state, async?, id), to: Validation.Strict.Params

  defdelegate validate_async_generator_function_name(state, async_generator?, id),
    to: Validation.Strict.Params

  defdelegate validate_async_params(state, async?, params), to: Validation.Strict.Params

  defdelegate validate_generator_body_bindings(state, generator?, body),
    to: Validation.Strict.Params

  defdelegate validate_generator_function_name(state, generator?, id),
    to: Validation.Strict.Params

  defdelegate validate_generator_params(state, generator?, params), to: Validation.Strict.Params
  defdelegate validate_unique_params(state, params), to: Validation.Strict.Params
  defdelegate validate_strict_function_name(state, id, body), to: Validation.Strict
  defdelegate validate_strict_program_bindings(state, body), to: Validation.Strict
  defdelegate validate_arrow_params(state, params, body), to: Validation.Strict
  defdelegate validate_strict_function_params(state, params, body), to: Validation.Strict
  defdelegate validate_strict_params(state, params), to: Validation.Strict
  defdelegate validate_strict_body_bindings(state, body), to: Validation.Strict

  defdelegate validate_module_declarations(state, body), to: Validation.Modules
  defdelegate validate_nested_module_declarations(state, body), to: Validation.Modules

  defdelegate validate_duplicate_proto_initializers(state, body), to: Validation.Proto

  defdelegate validate_yield_context(state, body), to: Validation.Context
  defdelegate validate_await_context(state, body), to: Validation.Context
  defdelegate validate_new_target_context(state, body), to: Validation.Context
  defdelegate validate_import_meta_context(state, body), to: Validation.Context
  defdelegate validate_super_context(state, body), to: Validation.Context
  defdelegate validate_super_params(state, params), to: Validation.Context
  defdelegate validate_class_super_calls(state, body), to: Validation.Context
  defdelegate validate_class_field_arguments(state, body), to: Validation.Context

  defdelegate validate_duplicate_private_names(state, body), to: Validation.PrivateNames
  defdelegate validate_declared_private_names(state, body), to: Validation.PrivateNames
  defdelegate validate_private_delete(state, body), to: Validation.PrivateNames
  defdelegate validate_private_super_access(state, body), to: Validation.PrivateNames
  defdelegate validate_private_in_expressions(state, body), to: Validation.PrivateNames

  defdelegate validate_duplicate_constructors(state, body), to: Validation.Targets
  defdelegate validate_class_element_names(state, body), to: Validation.Targets
  defdelegate validate_object_initializers(state, body), to: Validation.Targets
  defdelegate validate_optional_chain_base(state, left), to: Validation.Targets
  defdelegate validate_assignment_target(state, operator, left), to: Validation.Targets
  defdelegate validate_update_target(state, argument), to: Validation.Targets
end
