defmodule QuickBEAM.VM.Compiler.Lowering.State.Calls do
  @moduledoc "Call and invocation generation: unary/binary helpers, effectful push, invoke variants, tail calls, and block jumps."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Types}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  @line 1

  def nip_catch(
        %{stack: [val, _catch_offset | rest], stack_types: [type, _ | type_rest]} = state
      ),
      do: {:ok, %{state | stack: [val | rest], stack_types: [type | type_rest]}}

  def nip_catch(_state), do: {:error, :stack_underflow}

  def post_update(state, fun) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      result_type = if type == :integer, do: :integer, else: :number

      {pair, state} =
        bind(state, Builder.temp_name(state.temp), compiler_call(state, fun, [expr]))

      {:ok,
       %{
         state
         | stack: [Builder.tuple_element(pair, 1), Builder.tuple_element(pair, 2) | state.stack],
           stack_types: [result_type, result_type | state.stack_types]
       }}
    end
  end

  def effectful_push(state, expr),
    do: effectful_push(state, expr, Types.infer_expr_type(expr))

  def effectful_push(state, expr, type) do
    {bound, state} = bind(state, Builder.temp_name(state.temp), expr)
    {:ok, push(state, bound, type)}
  end

  def unary_call(state, mod, fun, extra_args \\ []) do
    with {:ok, expr, _type, state} <- pop_typed(state) do
      {:ok, push(state, Builder.remote_call(mod, fun, [expr | extra_args]))}
    end
  end

  def get_length_call(state) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      {result_expr, result_type} = specialize_get_length(expr, type)
      {:ok, push(state, result_expr, result_type)}
    end
  end

  def unary_local_call(state, fun) do
    with {:ok, expr, type, state} <- pop_typed(state) do
      {result_expr, result_type} = specialize_unary(fun, expr, type)
      {:ok, push(state, result_expr, result_type)}
    end
  end

  def binary_call(state, mod, fun) do
    with {:ok, right, _right_type, state} <- pop_typed(state),
         {:ok, left, _left_type, state} <- pop_typed(state) do
      {:ok, push(state, Builder.remote_call(mod, fun, [left, right]))}
    end
  end

  def binary_local_call(state, fun) do
    with {:ok, right, right_type, state} <- pop_typed(state),
         {:ok, left, left_type, state} <- pop_typed(state) do
      {result_expr, result_type} = specialize_binary(fun, left, left_type, right, right_type)
      {:ok, push(state, result_expr, result_type)}
    end
  end

  def invoke_call(state, argc) do
    with {:ok, args, arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, fun_type, state} <- pop_typed(state) do
      invoke_call_expr(state, fun, fun_type, Enum.reverse(args), Enum.reverse(arg_types))
    end
  end

  def invoke_constructor_call(state, argc) do
    with {:ok, args, _arg_types, state} <- pop_n_typed(state, argc),
         {:ok, new_target, _new_target_type, state} <- pop_typed(state),
         {:ok, ctor, _ctor_type, state} <- pop_typed(state) do
      effectful_push(
        state,
        compiler_call(state, :construct_runtime, [
          ctor,
          new_target,
          Builder.list_expr(Enum.reverse(args))
        ]),
        :object
      )
    end
  end

  def invoke_tail_call(state, argc) do
    with {:ok, args, arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, fun_type, %{stack: [], stack_types: []} = state} <- pop_typed(state) do
      {:done, tail_call_expr(state, fun, fun_type, Enum.reverse(args), Enum.reverse(arg_types))}
    else
      {:ok, _fun, _fun_type, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  def invoke_method_call(state, argc) do
    with {:ok, args, _arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, fun_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, state} <- pop_typed(state) do
      effectful_push(
        state,
        Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_method_runtime, [
          ctx_expr(state),
          fun,
          obj,
          Builder.list_expr(Enum.reverse(args))
        ]),
        function_return_type(fun_type, state.return_type)
      )
    end
  end

  def invoke_tail_method_call(state, argc) do
    with {:ok, args, _arg_types, state} <- pop_n_typed(state, argc),
         {:ok, fun, _fun_type, state} <- pop_typed(state),
         {:ok, obj, _obj_type, %{stack: [], stack_types: []} = state} <- pop_typed(state) do
      expr =
        Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_method_runtime, [
          ctx_expr(state),
          fun,
          obj,
          Builder.list_expr(Enum.reverse(args))
        ])

      {:done, Enum.reverse([expr | state.body])}
    else
      {:ok, _obj, _obj_type, _state} -> {:error, :stack_not_empty_on_tail_call}
      {:error, _} = error -> error
    end
  end

  def block_jump_call_values(target, stack_depths, ctx, slots, stack, capture_cells) do
    expected_depth = Map.get(stack_depths, target)
    actual_depth = length(stack)

    cond do
      is_nil(expected_depth) ->
        {:error, {:unknown_block_target, target}}

      expected_depth != actual_depth ->
        {:error, {:stack_depth_mismatch, target, expected_depth, actual_depth}}

      true ->
        {:ok,
         Builder.local_call(Builder.block_name(target), [
           ctx | slots ++ stack ++ capture_cells
         ])}
    end
  end

  def return_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:done, Enum.reverse([expr | state.body])}
    end
  end

  def throw_top(state) do
    with {:ok, expr, _state} <- pop(state) do
      {:done, Enum.reverse([Builder.throw_js(expr) | state.body])}
    end
  end

  def specialize_unary(:op_neg, expr, :integer), do: {{:op, @line, :-, expr}, :integer}
  def specialize_unary(:op_neg, expr, :number), do: {{:op, @line, :-, expr}, :number}
  def specialize_unary(:op_plus, expr, type) when type in [:integer, :number], do: {expr, type}
  def specialize_unary(fun, expr, _type), do: {Builder.local_call(fun, [expr]), :unknown}

  def specialize_binary(:op_add, left, :integer, right, :integer),
    do: {{:op, @line, :+, left, right}, :integer}

  def specialize_binary(:op_add, left, left_type, right, right_type)
      when left_type in [:integer, :number] and right_type in [:integer, :number],
      do:
        {{:op, @line, :+, left, right},
         if(left_type == :integer and right_type == :integer, do: :integer, else: :number)}

  def specialize_binary(:op_add, left, :string, right, :string),
    do: {binary_concat(left, right), :string}

  def specialize_binary(:op_strict_eq, left, type, right, type)
      when type in [:integer, :boolean, :string, :null, :undefined],
      do: {{:op, @line, :"=:=", left, right}, :boolean}

  def specialize_binary(:op_strict_neq, left, type, right, type)
      when type in [:integer, :boolean, :string, :null, :undefined],
      do: {{:op, @line, :"=/=", left, right}, :boolean}

  def specialize_binary(:op_mod, left, :integer, right, :integer),
    do: {{:op, @line, :rem, left, right}, :integer}

  def specialize_binary(fun, left, left_type, right, right_type)
      when fun in [:op_band, :op_bor, :op_bxor, :op_shl, :op_sar] and
             left_type in [:integer, :number] and right_type in [:integer, :number],
      do: {{:op, @line, binary_operator(fun), left, right}, :integer}

  def specialize_binary(fun, left, left_type, right, right_type)
      when fun in [:op_sub, :op_mul] and left_type == :integer and right_type == :integer,
      do: {{:op, @line, binary_operator(fun), left, right}, :integer}

  def specialize_binary(fun, left, left_type, right, right_type)
      when fun in [:op_sub, :op_mul, :op_div, :op_lt, :op_lte, :op_gt, :op_gte] and
             left_type in [:integer, :number] and right_type in [:integer, :number] do
    {type, op} =
      case fun do
        :op_sub -> {:number, :-}
        :op_mul -> {:number, :*}
        :op_div -> {:number, :/}
        :op_lt -> {:boolean, :<}
        :op_lte -> {:boolean, :"=<"}
        :op_gt -> {:boolean, :>}
        :op_gte -> {:boolean, :>=}
      end

    {{:op, @line, op, left, right}, type}
  end

  def specialize_binary(fun, left, _left_type, right, _right_type),
    do: {Builder.local_call(fun, [left, right]), :unknown}

  defp invoke_call_expr(%{return_type: return_type} = state, _fun, :self_fun, args, _arg_types) do
    effectful_push(
      state,
      Builder.local_call(:run_ctx, [ctx_expr(state) | normalize_self_call_args(state, args)]),
      return_type
    )
  end

  defp invoke_call_expr(state, fun, fun_type, args, _arg_types) do
    effectful_push(
      state,
      invoke_runtime_expr(state, fun, args),
      function_return_type(fun_type, state.return_type)
    )
  end

  defp tail_call_expr(state, _fun, :self_fun, args, _arg_types),
    do:
      Enum.reverse([
        Builder.local_call(:run_ctx, [ctx_expr(state) | normalize_self_call_args(state, args)])
        | state.body
      ])

  defp tail_call_expr(state, fun, _fun_type, args, _arg_types),
    do: Enum.reverse([invoke_runtime_expr(state, fun, args) | state.body])

  defp invoke_runtime_expr(state, fun, args) do
    case var_ref_fun_call(fun, length(args)) do
      {:ok, helper, idx, argc} when argc in 0..3 ->
        Builder.local_call(helper, [ctx_expr(state), idx | args])

      {:ok, helper, idx, _argc} ->
        Builder.local_call(helper, [ctx_expr(state), idx, Builder.list_expr(args)])

      :error ->
        Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_runtime, [
          ctx_expr(state),
          fun,
          Builder.list_expr(args)
        ])
    end
  end

  defp var_ref_fun_call(
         {:call, _, {:remote, _, {:atom, _, RuntimeHelpers}, {:atom, _, fun}}, [_ctx, idx]},
         argc
       )
       when fun in [:get_var_ref, :get_var_ref_check] do
    {:ok, invoke_var_ref_helper(fun, argc), idx, argc}
  end

  defp var_ref_fun_call(_expr, _argc), do: :error

  defp invoke_var_ref_helper(:get_var_ref, argc),
    do: invoke_var_ref_helper_name(:invoke_var_ref, argc)

  defp invoke_var_ref_helper(:get_var_ref_check, argc),
    do: invoke_var_ref_helper_name(:invoke_var_ref_check, argc)

  defp invoke_var_ref_helper_name(prefix, argc) when argc in 0..3,
    do: String.to_atom("op_#{prefix}#{argc}")

  defp invoke_var_ref_helper_name(prefix, _argc), do: String.to_atom("op_#{prefix}")

  defp function_return_type(:self_fun, return_type), do: return_type
  defp function_return_type({:function, type}, _return_type), do: type
  defp function_return_type(_fun_type, _return_type), do: :unknown

  defp normalize_self_call_args(%{arg_count: arg_count}, args) do
    args
    |> Enum.take(arg_count)
    |> then(fn args ->
      args ++ List.duplicate(Builder.atom(:undefined), arg_count - length(args))
    end)
  end

  defp specialize_get_length(expr, _type),
    do: {Builder.remote_call(QuickBEAM.VM.ObjectModel.Get, :length_of, [expr]), :integer}

  defp binary_operator(:op_sub), do: :-
  defp binary_operator(:op_mul), do: :*
  defp binary_operator(:op_mod), do: :rem
  defp binary_operator(:op_band), do: :band
  defp binary_operator(:op_bor), do: :bor
  defp binary_operator(:op_bxor), do: :bxor
  defp binary_operator(:op_shl), do: :bsl
  defp binary_operator(:op_sar), do: :bsr

  defp binary_concat(left, right) do
    {:bin, @line,
     [
       {:bin_element, @line, left, :default, [:binary]},
       {:bin_element, @line, right, :default, [:binary]}
     ]}
  end

  defp ctx_expr(%{ctx: ctx}), do: ctx

  defp bind(state, name, expr) do
    var = Builder.var(name)
    {var, %{state | body: [Builder.match(var, expr) | state.body], temp: state.temp + 1}}
  end

  defp push(state, expr), do: push(state, expr, Types.infer_expr_type(expr))

  defp push(state, expr, type),
    do: %{state | stack: [expr | state.stack], stack_types: [type | state.stack_types]}

  defp pop(%{stack: [expr | rest], stack_types: [_type | type_rest]} = state),
    do: {:ok, expr, %{state | stack: rest, stack_types: type_rest}}

  defp pop(_state), do: {:error, :stack_underflow}

  defp pop_typed(%{stack: [expr | rest], stack_types: [type | type_rest]} = state),
    do: {:ok, expr, type, %{state | stack: rest, stack_types: type_rest}}

  defp pop_typed(_state), do: {:error, :stack_underflow}

  defp pop_n_typed(state, 0), do: {:ok, [], [], state}

  defp pop_n_typed(state, count) when count > 0 do
    with {:ok, expr, type, state} <- pop_typed(state),
         {:ok, rest, rest_types, state} <- pop_n_typed(state, count - 1) do
      {:ok, [expr | rest], [type | rest_types], state}
    end
  end

  defp compiler_call(%{ctx: ctx}, fun, args),
    do: Builder.remote_call(RuntimeHelpers, fun, [ctx | args])
end
