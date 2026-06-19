defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Arithmetic do
  @moduledoc "Arithmetic, bitwise, comparison, and unary opcodes."

  alias QuickBEAM.VM.Compiler.BEAMForms
  alias QuickBEAM.VM.Compiler.Lowering.Operators
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    neg: {:unary_local, :op_neg},
    plus: {:unary_local, :op_plus},
    not: {:unary_abi, :bit_not},
    lnot: {:unary_abi, :lnot},
    is_undefined: {:unary_abi, :undefined?},
    is_null: {:unary_abi, :null?},
    is_undefined_or_null: :is_undefined_or_null,
    typeof_is_undefined: {:unary_abi, :typeof_is_undefined},
    typeof_is_function: {:unary_abi, :typeof_is_function},
    typeof: :typeof,
    inc: {:inc_dec, :+},
    dec: {:inc_dec, :-},
    post_inc: {:post_update, :post_inc},
    post_dec: {:post_update, :post_dec},
    add: {:binary_local, :op_add},
    sub: {:binary_local, :op_sub},
    mul: {:binary_local, :op_mul},
    div: {:binary_local, :op_div},
    mod: {:binary_local, :op_mod},
    pow: {:binary_abi, :pow},
    band: {:binary_local, :op_band},
    bor: {:binary_local, :op_bor},
    bxor: {:binary_local, :op_bxor},
    shl: {:binary_local, :op_shl},
    sar: {:binary_local, :op_sar},
    shr: {:binary_local, :op_shr},
    lt: {:binary_local, :op_lt},
    lte: {:binary_local, :op_lte},
    gt: {:binary_local, :op_gt},
    gte: {:binary_local, :op_gte},
    eq: {:binary_local, :op_eq},
    neq: {:binary_local, :op_neq},
    strict_eq: {:binary_local, :op_strict_eq},
    strict_neq: {:binary_local, :op_strict_neq}
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :arithmetic,
                        do: name

  if @invalid_handlers != [] do
    raise "arithmetic lowering handlers registered for non-arithmetic opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, {{:ok, name}, []}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      handler -> lower_handler(handler, state)
    end
  end

  def lower(_state, _name_args), do: :not_handled

  defp lower_handler({:unary_local, fun}, state), do: Operators.unary_local_call(state, fun)
  defp lower_handler({:unary_abi, fun}, state), do: Operators.unary_abi_call(state, fun)
  defp lower_handler({:binary_local, fun}, state), do: Operators.binary_local_call(state, fun)
  defp lower_handler({:binary_abi, fun}, state), do: Operators.binary_abi_call(state, fun)
  defp lower_handler({:inc_dec, op}, state), do: lower_inc_dec(state, op)
  defp lower_handler({:post_update, fun}, state), do: Operators.post_update(state, fun)
  defp lower_handler(:is_undefined_or_null, state), do: lower_is_undefined_or_null(state)

  defp lower_handler(:typeof, state) do
    with {:ok, expr, _type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, Builder.local_call(:op_typeof, [expr]))}
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
