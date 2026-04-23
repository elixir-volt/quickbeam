defmodule QuickBEAM.VM.Compiler.Lowering.Builder do
  @moduledoc false

  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.PredefinedAtoms

  @line 1

  def block_name(idx), do: String.to_atom("block_#{idx}")
  def slot_name(idx, n), do: "Slot#{idx}_#{n}"
  def capture_name(idx, n), do: "Capture#{idx}_#{n}"
  def temp_name(n), do: "Tmp#{n}"
  def ctx_var, do: var("Ctx")
  def slot_var(idx), do: var("Slot#{idx}")
  def stack_var(idx), do: var("Stack#{idx}")
  def capture_var(idx), do: var("Capture#{idx}")
  def slot_vars(0), do: []
  def slot_vars(count), do: Enum.map(0..(count - 1), &slot_var/1)
  def stack_vars(0), do: []
  def stack_vars(count), do: Enum.map(0..(count - 1), &stack_var/1)
  def capture_vars(0), do: []
  def capture_vars(count), do: Enum.map(0..(count - 1), &capture_var/1)

  def var(name) when is_binary(name), do: {:var, @line, String.to_atom(name)}
  def var(name) when is_integer(name), do: {:var, @line, String.to_atom(Integer.to_string(name))}
  def var(name) when is_atom(name), do: {:var, @line, name}

  def integer(value), do: {:integer, @line, value}
  def atom(value), do: {:atom, @line, value}
  def literal(value), do: :erl_parse.abstract(value)
  def match(left, right), do: {:match, @line, left, right}
  def tuple_expr(values), do: {:tuple, @line, values}

  def tuple_element(tuple, index) do
    remote_call(:erlang, :element, [integer(index), tuple])
  end

  def map_expr(entries) do
    {:map, @line, Enum.map(entries, fn {key, value} -> {:map_field_assoc, @line, key, value} end)}
  end

  def list_expr([]), do: {nil, @line}
  def list_expr([head | tail]), do: {:cons, @line, head, list_expr(tail)}

  def remote_call(mod, fun, args) do
    {:call, @line, {:remote, @line, literal(mod), {:atom, @line, fun}}, args}
  end

  def local_call(fun, args), do: {:call, @line, {:atom, @line, fun}, args}
  def compiler_call(fun, args), do: remote_call(RuntimeHelpers, fun, [ctx_var() | args])

  def throw_js(expr), do: remote_call(:erlang, :throw, [{:tuple, @line, [atom(:js_throw), expr]}])

  def try_catch_expr(try_body, err_var, catch_body) do
    {:try, @line, try_body, [], [catch_clause(err_var, catch_body)], []}
  end

  def undefined_or_null_expr(expr) do
    {:op, @line, :orelse, {:op, @line, :==, expr, atom(:undefined)},
     {:op, @line, :==, expr, atom(nil)}}
  end

  def branch_condition(expr, :boolean), do: expr

  def branch_condition({:call, _, {:atom, _, fun}, [left, right]} = expr, _type)
      when fun in [:op_lt, :op_lte, :op_gt, :op_gte],
      do: comparison_branch_condition(fun, left, right, expr)

  def branch_condition({:call, _, {:atom, _, fun}, _args} = expr, _type)
      when fun in [:op_eq, :op_neq, :op_strict_eq, :op_strict_neq],
      do: expr

  def branch_condition(expr, :integer), do: {:op, @line, :"=/=", expr, integer(0)}
  def branch_condition(_expr, :undefined), do: atom(false)
  def branch_condition(_expr, :null), do: atom(false)
  def branch_condition(expr, :string), do: {:op, @line, :"=/=", expr, literal("")}
  def branch_condition(_expr, :object), do: atom(true)
  def branch_condition(_expr, :function), do: atom(true)
  def branch_condition(_expr, {:function, _}), do: atom(true)
  def branch_condition(_expr, :self_fun), do: atom(true)
  def branch_condition(expr, _type), do: local_call(:op_truthy, [expr])
  def branch_case(expr, false_body, true_body), do: case_expr(expr, false_body, true_body)

  def atom_name(%{atoms: atoms}, atom_idx), do: resolve_atom_name(atom_idx, atoms)

  defp resolve_local_name(name, _atoms) when is_binary(name), do: name
  defp resolve_local_name({:predefined, idx}, _atoms), do: PredefinedAtoms.lookup(idx)

  defp resolve_local_name(idx, atoms)
       when is_integer(idx) and is_tuple(atoms) and idx >= 0 and idx < tuple_size(atoms),
       do: elem(atoms, idx)

  defp resolve_local_name(_name, _atoms), do: nil
  defp resolve_atom_name(atom_idx, atoms), do: resolve_local_name(atom_idx, atoms)

  defp comparison_branch_condition(fun, left, right, fallback_expr) do
    lhs = var(:BranchLhs)
    rhs = var(:BranchRhs)

    {:case, @line, tuple_expr([left, right]),
     [
       {:clause, @line, [tuple_expr([lhs, rhs])], [number_guards(lhs, rhs)],
        [{:op, @line, comparison_operator(fun), lhs, rhs}]},
       {:clause, @line, [var(:_)], [], [fallback_expr]}
     ]}
  end

  defp comparison_operator(:op_lt), do: :<
  defp comparison_operator(:op_lte), do: :"=<"
  defp comparison_operator(:op_gt), do: :>
  defp comparison_operator(:op_gte), do: :>=

  defp number_guards(a, b), do: [number_guard(a), number_guard(b)]
  defp number_guard(expr), do: {:call, @line, {:atom, @line, :is_number}, [expr]}

  defp case_expr(expr, false_body, true_body) do
    {:case, @line, expr,
     [
       {:clause, @line, [atom(false)], [], false_body},
       {:clause, @line, [atom(true)], [], true_body}
     ]}
  end

  defp catch_clause(err_var, catch_body) do
    pattern =
      {:tuple, @line, [atom(:throw), {:tuple, @line, [atom(:js_throw), err_var]}, var(:_)]}

    {:clause, @line, [pattern], [], catch_body}
  end
end
