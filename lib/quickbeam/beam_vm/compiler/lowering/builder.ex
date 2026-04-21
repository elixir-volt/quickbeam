defmodule QuickBEAM.BeamVM.Compiler.Lowering.Builder do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Lowering.State

  defdelegate block_name(idx), to: State
  defdelegate slot_name(idx, n), to: State
  defdelegate capture_name(idx, n), to: State
  defdelegate temp_name(n), to: State
  defdelegate slot_var(idx), to: State
  defdelegate stack_var(idx), to: State
  defdelegate capture_var(idx), to: State
  defdelegate slot_vars(count), to: State
  defdelegate stack_vars(count), to: State
  defdelegate capture_vars(count), to: State
  defdelegate var(name), to: State
  defdelegate integer(value), to: State
  defdelegate atom(value), to: State
  defdelegate literal(value), to: State
  defdelegate match(left, right), to: State
  defdelegate tuple_element(tuple, index), to: State
  defdelegate tuple_expr(values), to: State
  defdelegate map_expr(entries), to: State
  defdelegate list_expr(values), to: State
  defdelegate remote_call(mod, fun, args), to: State
  defdelegate local_call(fun, args), to: State
  defdelegate compiler_call(fun, args), to: State
  defdelegate throw_js(expr), to: State
  defdelegate try_catch_expr(try_body, err_var, catch_body), to: State
  defdelegate undefined_or_null_expr(expr), to: State
  defdelegate branch_condition(expr, type), to: State
  defdelegate branch_case(expr, false_body, true_body), to: State
end
