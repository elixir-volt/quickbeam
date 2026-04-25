defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Arithmetic do
  @moduledoc "Arithmetic, bitwise, comparison, and unary opcodes."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.Interpreter.Values

  def lower(state, name_args) do
    case name_args do
      {{:ok, :neg}, []} ->
        State.unary_local_call(state, :op_neg)

      {{:ok, :plus}, []} ->
        State.unary_local_call(state, :op_plus)

      {{:ok, :not}, []} ->
        State.unary_call(state, RuntimeHelpers, :bit_not)

      {{:ok, :lnot}, []} ->
        State.unary_call(state, RuntimeHelpers, :lnot)

      {{:ok, :is_undefined}, []} ->
        State.unary_call(state, RuntimeHelpers, :undefined?)

      {{:ok, :is_null}, []} ->
        State.unary_call(state, RuntimeHelpers, :null?)

      {{:ok, :is_undefined_or_null}, []} ->
        lower_is_undefined_or_null(state)

      {{:ok, :typeof_is_undefined}, []} ->
        State.unary_call(state, RuntimeHelpers, :typeof_is_undefined)

      {{:ok, :typeof_is_function}, []} ->
        State.unary_call(state, RuntimeHelpers, :typeof_is_function)

      {{:ok, :typeof}, []} ->
        with {:ok, expr, _type, state} <- State.pop_typed(state) do
          {:ok, State.push(state, Builder.local_call(:op_typeof, [expr]))}
        end

      {{:ok, :inc}, []} ->
        lower_inc_dec(state, :+)

      {{:ok, :dec}, []} ->
        lower_inc_dec(state, :-)

      {{:ok, :post_inc}, []} ->
        State.post_update(state, :post_inc)

      {{:ok, :post_dec}, []} ->
        State.post_update(state, :post_dec)

      {{:ok, :add}, []} ->
        State.binary_local_call(state, :op_add)

      {{:ok, :sub}, []} ->
        State.binary_local_call(state, :op_sub)

      {{:ok, :mul}, []} ->
        State.binary_local_call(state, :op_mul)

      {{:ok, :div}, []} ->
        State.binary_local_call(state, :op_div)

      {{:ok, :mod}, []} ->
        State.binary_call(state, Values, :mod)

      {{:ok, :pow}, []} ->
        State.binary_call(state, Values, :pow)

      {{:ok, :band}, []} ->
        State.binary_call(state, Values, :band)

      {{:ok, :bor}, []} ->
        State.binary_call(state, Values, :bor)

      {{:ok, :bxor}, []} ->
        State.binary_call(state, Values, :bxor)

      {{:ok, :shl}, []} ->
        State.binary_call(state, Values, :shl)

      {{:ok, :sar}, []} ->
        State.binary_call(state, Values, :sar)

      {{:ok, :shr}, []} ->
        State.binary_call(state, Values, :shr)

      {{:ok, :lt}, []} ->
        State.binary_local_call(state, :op_lt)

      {{:ok, :lte}, []} ->
        State.binary_local_call(state, :op_lte)

      {{:ok, :gt}, []} ->
        State.binary_local_call(state, :op_gt)

      {{:ok, :gte}, []} ->
        State.binary_local_call(state, :op_gte)

      {{:ok, :eq}, []} ->
        State.binary_local_call(state, :op_eq)

      {{:ok, :neq}, []} ->
        State.binary_local_call(state, :op_neq)

      {{:ok, :strict_eq}, []} ->
        State.binary_local_call(state, :op_strict_eq)

      {{:ok, :strict_neq}, []} ->
        State.binary_local_call(state, :op_strict_neq)

      _ ->
        :not_handled
    end
  end

  defp lower_inc_dec(state, op) do
    with {:ok, expr, type, state} <- State.pop_typed(state) do
      {result_expr, result_type} =
        if type == :integer do
          {{:op, 1, op, expr, {:integer, 1, 1}}, :integer}
        else
          fun = if op == :+, do: :inc, else: :dec
          {State.compiler_call(state, fun, [expr]), :unknown}
        end

      {:ok, State.push(state, result_expr, result_type)}
    end
  end

  defp lower_is_undefined_or_null(state) do
    with {:ok, expr, type, state} <- State.pop_typed(state) do
      result =
        case type do
          :undefined -> Builder.atom(true)
          :null -> Builder.atom(true)
          _ -> Builder.undefined_or_null_expr(expr)
        end

      {:ok, State.push(state, result, :boolean)}
    end
  end
end
