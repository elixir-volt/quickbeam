defmodule QuickBEAM.VM.Compiler.Lowering.Operators do
  @moduledoc "Unary, binary, and update operator lowering helpers."

  alias QuickBEAM.VM.Compiler.{BeamForms, RuntimeABI}
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit}

  @line BeamForms.line()

  def post_update(state, fun) do
    with {:ok, expr, type, state} <- Emit.pop_typed(state) do
      if type == :integer do
        op = if fun == :post_inc, do: :+, else: :-

        {new_val, state} =
          Emit.bind(
            state,
            Builder.temp_name(state.temp),
            {:op, @line, op, expr, {:integer, @line, 1}}
          )

        {:ok,
         %{
           state
           | stack: [new_val, expr | state.stack],
             stack_types: [:integer, :integer | state.stack_types]
         }}
      else
        {pair, state} =
          Emit.bind(state, Builder.temp_name(state.temp), abi_call(state, fun, [expr]))

        {:ok,
         %{
           state
           | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
             stack_types: [:number, :number | state.stack_types]
         }}
      end
    end
  end

  def unary_call(state, mod, fun, extra_args \\ []) do
    with {:ok, expr, _type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, Builder.remote_call(mod, fun, [expr | extra_args]))}
    end
  end

  def unary_abi_call(state, fun) do
    with {:ok, expr, _type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, Builder.remote_call(RuntimeABI, fun, [state.ctx, expr]))}
    end
  end

  def get_length_call(state) do
    with {:ok, expr, type, state} <- Emit.pop_typed(state) do
      {result_expr, result_type} = specialize_get_length(expr, type)
      {:ok, Emit.push(state, result_expr, result_type)}
    end
  end

  def unary_local_call(state, fun) do
    with {:ok, expr, type, state} <- Emit.pop_typed(state) do
      {result_expr, result_type} = specialize_unary(fun, expr, type)
      {:ok, Emit.push(state, result_expr, result_type)}
    end
  end

  def binary_call(state, mod, fun) do
    with {:ok, right, _right_type, state} <- Emit.pop_typed(state),
         {:ok, left, _left_type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, Builder.remote_call(mod, fun, [left, right]))}
    end
  end

  def binary_abi_call(state, fun) do
    with {:ok, right, _right_type, state} <- Emit.pop_typed(state),
         {:ok, left, _left_type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, abi_call(state, fun, [left, right]))}
    end
  end

  def binary_local_call(state, fun) do
    with {:ok, right, right_type, state} <- Emit.pop_typed(state),
         {:ok, left, left_type, state} <- Emit.pop_typed(state) do
      {result_expr, result_type} = specialize_binary(fun, left, left_type, right, right_type)
      {:ok, Emit.push(state, result_expr, result_type)}
    end
  end

  def specialize_unary(:op_neg, expr, :integer),
    do: {Builder.local_call(:op_neg, [expr]), :number}

  def specialize_unary(:op_neg, expr, :number), do: {{:op, @line, :-, expr}, :number}
  def specialize_unary(:op_plus, expr, type) when type in [:integer, :number], do: {expr, type}
  def specialize_unary(fun, expr, _type), do: {Builder.local_call(fun, [expr]), :unknown}

  def specialize_binary(:op_add, left, :integer, right, :integer),
    do: {{:op, @line, :+, left, right}, :integer}

  def specialize_binary(:op_add, left, left_type, right, right_type)
      when left_type in [:integer, :number] and right_type in [:integer, :number],
      do: {Builder.local_call(:op_add, [left, right]), :number}

  def specialize_binary(:op_add, left, :string, right, :string),
    do: {binary_concat(left, right), :string}

  def specialize_binary(:op_strict_eq, left, type, right, type)
      when type in [:integer, :boolean, :string, :null, :undefined],
      do: {{:op, @line, :"=:=", left, right}, :boolean}

  def specialize_binary(:op_strict_neq, left, type, right, type)
      when type in [:integer, :boolean, :string, :null, :undefined],
      do: {{:op, @line, :"=/=", left, right}, :boolean}

  def specialize_binary(:op_mod, left, :integer, right, :integer),
    do: {Builder.local_call(:op_mod, [left, right]), :number}

  def specialize_binary(fun, left, left_type, right, right_type)
      when fun in [:op_band, :op_bor, :op_bxor] and
             left_type in [:integer, :number] and right_type in [:integer, :number],
      do: {{:op, @line, binary_operator(fun), left, right}, :integer}

  def specialize_binary(fun, left, left_type, right, right_type)
      when fun in [:op_sub, :op_mul] and left_type == :integer and right_type == :integer,
      do: {{:op, @line, binary_operator(fun), left, right}, :integer}

  def specialize_binary(fun, left, left_type, right, right_type)
      when fun in [:op_lt, :op_lte, :op_gt, :op_gte] and
             left_type in [:integer, :number] and right_type in [:integer, :number] do
    {type, op} =
      case fun do
        :op_lt -> {:boolean, :<}
        :op_lte -> {:boolean, :"=<"}
        :op_gt -> {:boolean, :>}
        :op_gte -> {:boolean, :>=}
      end

    {{:op, @line, op, left, right}, type}
  end

  def specialize_binary(fun, left, _left_type, right, _right_type),
    do: {Builder.local_call(fun, [left, right]), :unknown}

  defp abi_call(state, fun, args), do: Builder.remote_call(RuntimeABI, fun, [state.ctx | args])

  defp specialize_get_length(expr, _type),
    do: {Builder.remote_call(RuntimeABI, :length_of, [Builder.ctx_var(), expr]), :integer}

  defp binary_operator(:op_sub), do: :-
  defp binary_operator(:op_mul), do: :*
  defp binary_operator(:op_band), do: :band
  defp binary_operator(:op_bor), do: :bor
  defp binary_operator(:op_bxor), do: :bxor

  defp binary_concat(left, right), do: BeamForms.binary_concat(left, right)
end
