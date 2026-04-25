defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Stack do
  @moduledoc "Stack manipulation opcodes: push constants, dup, drop, swap, rot, perm, insert, nip, nop."

  alias QuickBEAM.VM.Bytecode
  alias QuickBEAM.VM.Compiler.Analysis.Types, as: AnalysisTypes
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Captures, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  def lower(state, constants, arg_count, name_args) do
    case name_args do
      {{:ok, :push_i32}, [value]} ->
        {:ok, State.push(state, Builder.integer(value))}

      {{:ok, :push_i16}, [value]} ->
        {:ok, State.push(state, Builder.integer(value))}

      {{:ok, :push_i8}, [value]} ->
        {:ok, State.push(state, Builder.integer(value))}

      {{:ok, :push_minus1}, [_]} ->
        {:ok, State.push(state, Builder.integer(-1))}

      {{:ok, :push_0}, [_]} ->
        {:ok, State.push(state, Builder.integer(0))}

      {{:ok, :push_1}, [_]} ->
        {:ok, State.push(state, Builder.integer(1))}

      {{:ok, :push_2}, [_]} ->
        {:ok, State.push(state, Builder.integer(2))}

      {{:ok, :push_3}, [_]} ->
        {:ok, State.push(state, Builder.integer(3))}

      {{:ok, :push_4}, [_]} ->
        {:ok, State.push(state, Builder.integer(4))}

      {{:ok, :push_5}, [_]} ->
        {:ok, State.push(state, Builder.integer(5))}

      {{:ok, :push_6}, [_]} ->
        {:ok, State.push(state, Builder.integer(6))}

      {{:ok, :push_7}, [_]} ->
        {:ok, State.push(state, Builder.integer(7))}

      {{:ok, :push_true}, []} ->
        {:ok, State.push(state, Builder.atom(true))}

      {{:ok, :push_false}, []} ->
        {:ok, State.push(state, Builder.atom(false))}

      {{:ok, :null}, []} ->
        {:ok, State.push(state, Builder.atom(nil))}

      {{:ok, :undefined}, []} ->
        {:ok, State.push(state, Builder.atom(:undefined))}

      {{:ok, :push_empty_string}, []} ->
        {:ok, State.push(state, Builder.literal(""))}

      {{:ok, :push_bigint_i32}, [value]} ->
        {:ok,
         State.push(state, Builder.tuple_expr([Builder.atom(:bigint), Builder.integer(value)]))}

      {{:ok, :push_atom_value}, [atom_idx]} ->
        {:ok, State.push(state, Builder.literal(Builder.atom_name(state, atom_idx)), :string)}

      {{:ok, :push_this}, []} ->
        {:ok, State.push(state, State.compiler_call(state, :push_this, []), :object)}

      {{:ok, :push_const}, [const_idx]} ->
        push_const(state, constants, arg_count, const_idx)

      {{:ok, :push_const8}, [const_idx]} ->
        push_const(state, constants, arg_count, const_idx)

      {{:ok, :fclosure}, [const_idx]} ->
        lower_fclosure(state, constants, arg_count, const_idx)

      {{:ok, :fclosure8}, [const_idx]} ->
        lower_fclosure(state, constants, arg_count, const_idx)

      {{:ok, :private_symbol}, [atom_idx]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :private_symbol, [
             Builder.literal(Builder.atom_name(state, atom_idx))
           ]),
           :unknown
         )}

      {{:ok, :dup}, []} ->
        State.duplicate_top(state)

      {{:ok, :dup1}, []} ->
        lower_dup1(state)

      {{:ok, :dup2}, []} ->
        State.duplicate_top_two(state)

      {{:ok, :dup3}, []} ->
        lower_dup3(state)

      {{:ok, :insert2}, []} ->
        State.insert_top_two(state)

      {{:ok, :insert3}, []} ->
        State.insert_top_three(state)

      {{:ok, :insert4}, []} ->
        lower_insert4(state)

      {{:ok, :drop}, []} ->
        State.drop_top(state)

      {{:ok, :nip}, []} ->
        lower_nip(state)

      {{:ok, :nip1}, []} ->
        lower_nip1(state)

      {{:ok, :swap}, []} ->
        State.swap_top(state)

      {{:ok, :swap2}, []} ->
        lower_swap2(state)

      {{:ok, :rot3l}, []} ->
        lower_rot3l(state)

      {{:ok, :rot3r}, []} ->
        lower_rot3r(state)

      {{:ok, :rot4l}, []} ->
        lower_rot4l(state)

      {{:ok, :rot5l}, []} ->
        lower_rot5l(state)

      {{:ok, :perm3}, []} ->
        State.permute_top_three(state)

      {{:ok, :perm4}, []} ->
        lower_perm4(state)

      {{:ok, :perm5}, []} ->
        lower_perm5(state)

      {{:ok, :nop}, []} ->
        {:ok, state}

      _ ->
        :not_handled
    end
  end

  defp push_const(state, constants, arg_count, idx) do
    case Enum.at(constants, idx) do
      nil ->
        {:error, {:unsupported_const, idx}}

      value
      when is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
             is_nil(value) ->
        {:ok, State.push(state, Builder.literal(value))}

      :undefined ->
        {:ok, State.push(state, Builder.atom(:undefined), :undefined)}

      %Bytecode.Function{} = fun when fun.closure_vars == [] ->
        {:ok, State.push(state, Builder.literal(fun), AnalysisTypes.function_type(fun))}

      %Bytecode.Function{} ->
        lower_fclosure(state, constants, arg_count, idx)

      _ ->
        {:error, {:unsupported_const, idx}}
    end
  end

  defp lower_fclosure(state, constants, arg_count, const_idx) do
    case Enum.at(constants, const_idx) do
      %Bytecode.Function{closure_vars: []} = fun ->
        {:ok, State.push(state, Builder.literal(fun), AnalysisTypes.function_type(fun))}

      %Bytecode.Function{} = fun ->
        with {:ok, state, entries} <-
               lower_closure_entries(state, arg_count, fun.closure_vars, []) do
          closure =
            Builder.tuple_expr([
              Builder.atom(:closure),
              Builder.map_expr(Enum.reverse(entries)),
              Builder.literal(fun)
            ])

          {:ok, State.push(state, closure, AnalysisTypes.function_type(fun))}
        end

      nil ->
        {:error, {:unsupported_const, const_idx}}

      other ->
        {:error, {:unsupported_fclosure_const, const_idx, other}}
    end
  end

  defp lower_closure_entries(state, _arg_count, [], acc), do: {:ok, state, acc}

  defp lower_closure_entries(
         state,
         arg_count,
         [%{closure_type: 2, var_idx: idx} = cv | rest],
         acc
       ) do
    {parent_ref, state} =
      State.bind(
        state,
        Builder.temp_name(state.temp),
        Builder.remote_call(RuntimeHelpers, :get_var_ref, [
          State.ctx_expr(state),
          Builder.literal(idx)
        ])
      )

    {cell, state} =
      State.bind(
        state,
        Builder.temp_name(state.temp),
        State.compiler_call(state, :ensure_capture_cell, [parent_ref, parent_ref])
      )

    key = Builder.literal({cv.closure_type, cv.var_idx})
    lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
  end

  defp lower_closure_entries(state, arg_count, [cv | rest], acc) do
    with {:ok, slot_idx} <- closure_slot_index(arg_count, cv),
         {:ok, state, cell} <- Captures.ensure_capture_cell(state, slot_idx) do
      key = Builder.literal({cv.closure_type, cv.var_idx})
      lower_closure_entries(state, arg_count, rest, [{key, cell} | acc])
    end
  end

  defp closure_slot_index(_arg_count, %{closure_type: 1, var_idx: idx}), do: {:ok, idx}
  defp closure_slot_index(arg_count, %{closure_type: 0, var_idx: idx}), do: {:ok, idx + arg_count}

  defp closure_slot_index(_arg_count, %{closure_type: 2, var_idx: idx}),
    do: {:error, {:closure_var_ref_not_supported, idx}}

  defp closure_slot_index(_arg_count, %{closure_type: type, var_idx: idx}),
    do: {:error, {:closure_type_not_supported, type, idx}}

  defp lower_dup1(state) do
    with {:ok, a, ta, state} <- State.pop_typed(state),
         {:ok, b, tb, state} <- State.pop_typed(state) do
      {b_bound, state} = State.bind(state, Builder.temp_name(state.temp), b)
      {a_bound, state} = State.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b_bound, a_bound, b_bound | state.stack],
           stack_types: [ta, tb, ta, tb | state.stack_types]
       }}
    end
  end

  defp lower_dup3(state) do
    with {:ok, a, ta, state} <- State.pop_typed(state),
         {:ok, b, tb, state} <- State.pop_typed(state),
         {:ok, c, tc, state} <- State.pop_typed(state) do
      {c_bound, state} = State.bind(state, Builder.temp_name(state.temp), c)
      {b_bound, state} = State.bind(state, Builder.temp_name(state.temp), b)
      {a_bound, state} = State.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b_bound, c_bound, a_bound, b_bound, c_bound | state.stack],
           stack_types: [ta, tb, tc, ta, tb, tc | state.stack_types]
       }}
    end
  end

  defp lower_insert4(state) do
    with {:ok, a, ta, state} <- State.pop_typed(state),
         {:ok, b, tb, state} <- State.pop_typed(state),
         {:ok, c, tc, state} <- State.pop_typed(state),
         {:ok, d, td, state} <- State.pop_typed(state) do
      {a_bound, state} = State.bind(state, Builder.temp_name(state.temp), a)

      {:ok,
       %{
         state
         | stack: [a_bound, b, c, d, a_bound | state.stack],
           stack_types: [ta, tb, tc, td, ta | state.stack_types]
       }}
    end
  end

  defp lower_nip(%{stack: [a, _b | rest], stack_types: [ta, _tb | type_rest]} = state),
    do: {:ok, %{state | stack: [a | rest], stack_types: [ta | type_rest]}}

  defp lower_nip(_state), do: {:error, :stack_underflow}

  defp lower_nip1(%{stack: [a, b, _c | rest], stack_types: [ta, tb, _tc | type_rest]} = state),
    do: {:ok, %{state | stack: [a, b | rest], stack_types: [ta, tb | type_rest]}}

  defp lower_nip1(_state), do: {:error, :stack_underflow}

  defp lower_swap2(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [c, d, a, b | rest], stack_types: [tc, td, ta, tb | type_rest]}}

  defp lower_swap2(_state), do: {:error, :stack_underflow}

  defp lower_rot3l(%{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state),
    do: {:ok, %{state | stack: [c, a, b | rest], stack_types: [tc, ta, tb | type_rest]}}

  defp lower_rot3l(_state), do: {:error, :stack_underflow}

  defp lower_rot3r(%{stack: [a, b, c | rest], stack_types: [ta, tb, tc | type_rest]} = state),
    do: {:ok, %{state | stack: [b, c, a | rest], stack_types: [tb, tc, ta | type_rest]}}

  defp lower_rot3r(_state), do: {:error, :stack_underflow}

  defp lower_rot4l(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [d, a, b, c | rest], stack_types: [td, ta, tb, tc | type_rest]}}

  defp lower_rot4l(_state), do: {:error, :stack_underflow}

  defp lower_rot5l(
         %{
           stack: [a, b, c, d, e | rest],
           stack_types: [ta, tb, tc, td, te | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{
            state
            | stack: [e, a, b, c, d | rest],
              stack_types: [te, ta, tb, tc, td | type_rest]
          }}

  defp lower_rot5l(_state), do: {:error, :stack_underflow}

  defp lower_perm4(
         %{
           stack: [a, b, c, d | rest],
           stack_types: [ta, tb, tc, td | type_rest]
         } = state
       ),
       do: {:ok, %{state | stack: [a, c, d, b | rest], stack_types: [ta, tc, td, tb | type_rest]}}

  defp lower_perm4(_state), do: {:error, :stack_underflow}

  defp lower_perm5(
         %{
           stack: [a, b, c, d, e | rest],
           stack_types: [ta, tb, tc, td, te | type_rest]
         } = state
       ),
       do:
         {:ok,
          %{
            state
            | stack: [a, c, d, e, b | rest],
              stack_types: [ta, tc, td, te, tb | type_rest]
          }}

  defp lower_perm5(_state), do: {:error, :stack_underflow}

end
