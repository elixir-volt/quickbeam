defmodule QuickBEAM.VM.Compiler.Lowering.Builder do
  @moduledoc "Erlang abstract-format helpers: variable, literal, call, and case-clause constructors for the lowering pass."

  alias QuickBEAM.VM.Compiler.{BEAMForms, Lowering.Atoms}

  @doc "Returns the generated Erlang function name for a bytecode block."
  def block_name(idx), do: BEAMForms.block_name(idx)
  def slot_name(idx, n), do: "Slot#{idx}_#{n}"
  def capture_name(idx, n), do: "Capture#{idx}_#{n}"
  def temp_name(n), do: "Tmp#{n}"
  def ctx_var, do: var("Ctx")
  def slot_var(idx), do: var("Slot#{idx}")
  def stack_var(idx), do: var("Stack#{idx}")
  def capture_var(idx), do: var("Capture#{idx}")
  @doc "Returns generated Erlang variables for all local slots."
  def slot_vars(0), do: []
  def slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  def stack_vars(0), do: []
  def stack_vars(count), do: Enum.map(0..(count - 1), &stack_var/1)
  def capture_vars(0), do: []
  def capture_vars(count), do: Enum.map(0..(count - 1), &capture_var/1)

  def var(name), do: BEAMForms.var(name)

  @doc "Builds an Erlang abstract-format integer literal."
  def integer(value), do: BEAMForms.integer(value)
  def atom(value), do: BEAMForms.atom(value)
  def literal(value), do: BEAMForms.literal(value)
  def match(left, right), do: BEAMForms.match(left, right)
  def tuple_expr(values), do: BEAMForms.tuple(values)

  def tuple_element(tuple, index), do: BEAMForms.tuple_element(tuple, index)

  @doc "Builds an Erlang abstract-format map expression."
  def map_expr(entries), do: BEAMForms.map(entries)

  def map_get(map, key), do: BEAMForms.map_get(map, key)

  def list_expr(values), do: BEAMForms.list(values)

  def anonymous_fun(args, guards, body), do: BEAMForms.anonymous_fun(args, guards, body)

  def remote_call(mod, fun, args), do: BEAMForms.remote_call(mod, fun, args)

  @doc "Builds an Erlang abstract-format local call expression."
  def local_call(fun, args), do: BEAMForms.local_call(fun, args)

  def throw_js(expr), do: remote_call(:erlang, :throw, [tuple_expr([atom(:js_throw), expr])])

  def try_catch_expr(try_body, err_var, catch_body) do
    BEAMForms.try_catch(try_body, [catch_clause(err_var, catch_body)])
  end

  @doc "Builds a guard-style expression checking `undefined` or `null`."
  def equal(left, right), do: BEAMForms.equal(left, right)
  def is_integer_guard(expr), do: BEAMForms.is_integer_guard(expr)
  def is_number_guard(expr), do: BEAMForms.is_number_guard(expr)
  def is_boolean_guard(expr), do: BEAMForms.is_boolean_guard(expr)
  def is_binary_guard(expr), do: BEAMForms.is_binary_guard(expr)

  def undefined_or_null_expr(expr) do
    BEAMForms.or_else(BEAMForms.equal(expr, atom(:undefined)), BEAMForms.equal(expr, atom(nil)))
  end

  def branch_condition(expr, :boolean), do: expr

  def branch_condition({:call, _, {:atom, _, fun}, [left, right]} = expr, _type)
      when fun in [:op_lt, :op_lte, :op_gt, :op_gte],
      do: comparison_branch_condition(fun, left, right, expr)

  def branch_condition({:call, _, {:atom, _, fun}, _args} = expr, _type)
      when fun in [:op_eq, :op_neq, :op_strict_eq, :op_strict_neq],
      do: expr

  def branch_condition(expr, :integer), do: BEAMForms.not_equal(expr, integer(0))
  def branch_condition(_expr, :undefined), do: atom(false)
  def branch_condition(_expr, :null), do: atom(false)
  def branch_condition(expr, :string), do: BEAMForms.not_equal(expr, literal(""))
  def branch_condition(_expr, :object), do: atom(true)
  def branch_condition(_expr, :function), do: atom(true)
  def branch_condition(_expr, {:function, _}), do: atom(true)
  def branch_condition(_expr, :self_fun), do: atom(true)
  def branch_condition(expr, _type), do: local_call(:op_truthy, [expr])
  @doc "Builds a boolean case expression with false and true branches."
  def branch_case(expr, false_body, true_body), do: case_expr(expr, false_body, true_body)

  def atom_name(%{atoms: atoms}, atom_idx), do: Atoms.resolve(atom_idx, atoms)

  defp comparison_branch_condition(fun, left, right, fallback_expr) do
    id = System.unique_integer([:positive])
    lhs = var(:"BranchLhs#{id}")
    rhs = var(:"BranchRhs#{id}")

    BEAMForms.case_(tuple_expr([left, right]), [
      BEAMForms.clause(
        [tuple_expr([lhs, rhs])],
        [number_guards(lhs, rhs)],
        [BEAMForms.op(comparison_operator(fun), lhs, rhs)]
      ),
      BEAMForms.clause([var(:_)], [], [fallback_expr])
    ])
  end

  defp comparison_operator(:op_lt), do: :<
  defp comparison_operator(:op_lte), do: :"=<"
  defp comparison_operator(:op_gt), do: :>
  defp comparison_operator(:op_gte), do: :>=

  defp number_guards(a, b), do: [number_guard(a), number_guard(b)]
  defp number_guard(expr), do: BEAMForms.is_number_guard(expr)

  defp case_expr(expr, false_body, true_body) do
    BEAMForms.case_(expr, [BEAMForms.false_clause(false_body), BEAMForms.true_clause(true_body)])
  end

  defp catch_clause(err_var, catch_body) do
    pattern =
      tuple_expr([atom(:throw), tuple_expr([atom(:js_throw), err_var]), var(:_)])

    BEAMForms.clause([pattern], [], catch_body)
  end
end
