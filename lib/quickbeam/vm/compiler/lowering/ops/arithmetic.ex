defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Arithmetic do
  @moduledoc "Arithmetic, bitwise, comparison, and unary opcodes."

  alias QuickBEAM.VM.Compiler.BEAMForms
  alias QuickBEAM.VM.Compiler.Lowering.Operators
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, :neg}, []} ->
        Operators.unary_local_call(state, :op_neg)

      {{:ok, :plus}, []} ->
        Operators.unary_local_call(state, :op_plus)

      {{:ok, :not}, []} ->
        Operators.unary_abi_call(state, :bit_not)

      {{:ok, :lnot}, []} ->
        Operators.unary_abi_call(state, :lnot)

      {{:ok, :is_undefined}, []} ->
        Operators.unary_abi_call(state, :undefined?)

      {{:ok, :is_null}, []} ->
        Operators.unary_abi_call(state, :null?)

      {{:ok, :is_undefined_or_null}, []} ->
        lower_is_undefined_or_null(state)

      {{:ok, :typeof_is_undefined}, []} ->
        Operators.unary_abi_call(state, :typeof_is_undefined)

      {{:ok, :typeof_is_function}, []} ->
        Operators.unary_abi_call(state, :typeof_is_function)

      {{:ok, :typeof}, []} ->
        with {:ok, expr, _type, state} <- Emit.pop_typed(state) do
          {:ok, Emit.push(state, Builder.local_call(:op_typeof, [expr]))}
        end

      {{:ok, :inc}, []} ->
        lower_inc_dec(state, :+)

      {{:ok, :dec}, []} ->
        lower_inc_dec(state, :-)

      {{:ok, :post_inc}, []} ->
        Operators.post_update(state, :post_inc)

      {{:ok, :post_dec}, []} ->
        Operators.post_update(state, :post_dec)

      {{:ok, :add}, []} ->
        Operators.binary_local_call(state, :op_add)

      {{:ok, :sub}, []} ->
        Operators.binary_local_call(state, :op_sub)

      {{:ok, :mul}, []} ->
        Operators.binary_local_call(state, :op_mul)

      {{:ok, :div}, []} ->
        Operators.binary_local_call(state, :op_div)

      {{:ok, :mod}, []} ->
        Operators.binary_local_call(state, :op_mod)

      {{:ok, :pow}, []} ->
        Operators.binary_abi_call(state, :pow)

      {{:ok, :band}, []} ->
        Operators.binary_local_call(state, :op_band)

      {{:ok, :bor}, []} ->
        Operators.binary_local_call(state, :op_bor)

      {{:ok, :bxor}, []} ->
        Operators.binary_local_call(state, :op_bxor)

      {{:ok, :shl}, []} ->
        Operators.binary_local_call(state, :op_shl)

      {{:ok, :sar}, []} ->
        Operators.binary_local_call(state, :op_sar)

      {{:ok, :shr}, []} ->
        Operators.binary_local_call(state, :op_shr)

      {{:ok, :lt}, []} ->
        Operators.binary_local_call(state, :op_lt)

      {{:ok, :lte}, []} ->
        Operators.binary_local_call(state, :op_lte)

      {{:ok, :gt}, []} ->
        Operators.binary_local_call(state, :op_gt)

      {{:ok, :gte}, []} ->
        Operators.binary_local_call(state, :op_gte)

      {{:ok, :eq}, []} ->
        Operators.binary_local_call(state, :op_eq)

      {{:ok, :neq}, []} ->
        Operators.binary_local_call(state, :op_neq)

      {{:ok, :strict_eq}, []} ->
        Operators.binary_local_call(state, :op_strict_eq)

      {{:ok, :strict_neq}, []} ->
        Operators.binary_local_call(state, :op_strict_neq)

      _ ->
        :not_handled
    end
  end

  defp lower_inc_dec(state, op) do
    with {:ok, expr, type, state} <- Emit.pop_typed(state) do
      {result_expr, result_type} =
        if type == :integer do
          {BEAMForms.op(op, expr, Builder.integer(1)), :integer}
        else
          fun = if op == :+, do: :inc, else: :dec
          {State.abi_call(state, fun, [expr]), :unknown}
        end

      {:ok, Emit.push(state, result_expr, result_type)}
    end
  end

  defp lower_is_undefined_or_null(state) do
    with {:ok, expr, type, state} <- Emit.pop_typed(state) do
      result =
        case type do
          :undefined -> Builder.atom(true)
          :null -> Builder.atom(true)
          _ -> Builder.undefined_or_null_expr(expr)
        end

      {:ok, Emit.push(state, result, :boolean)}
    end
  end
end
