defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Globals do
  @moduledoc "Global variable and var-ref opcodes: get_var, put_var, define_var, get_var_ref, make_*_ref, get/put_ref_value."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.GlobalEnv

  @doc "Lowers a bytecode instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, :get_var}, [atom_idx]} ->
        name = Builder.atom_name(state, atom_idx)

        if is_binary(name) do
          {:ok, State.push(state, inline_get_var(state, name))}
        else
          {:ok,
           State.push(
             state,
             State.compiler_call(state, :get_var, [Builder.literal(name)])
           )}
        end

      {{:ok, :get_var_undef}, [atom_idx]} ->
        name = Builder.atom_name(state, atom_idx)

        if is_binary(name) do
          {:ok, State.push(state, inline_get_var_undef(state, name))}
        else
          {:ok,
           State.push(
             state,
             State.compiler_call(state, :get_var_undef, [Builder.literal(name)])
           )}
        end

      {{:ok, :put_var}, [atom_idx]} ->
        lower_put_var(state, atom_idx)

      {{:ok, :put_var_init}, [atom_idx]} ->
        lower_put_var(state, atom_idx)

      {{:ok, :define_func}, [atom_idx, _flags]} ->
        lower_put_var(state, atom_idx)

      {{:ok, :define_var}, [atom_idx, _scope]} ->
        {:ok,
         State.update_ctx(
           state,
           Builder.remote_call(GlobalEnv, :define_var, [
             State.ctx_expr(state),
             Builder.literal(atom_idx)
           ])
         )}

      {{:ok, :check_define_var}, [atom_idx, _scope]} ->
        {:ok,
         State.update_ctx(
           state,
           Builder.remote_call(GlobalEnv, :check_define_var, [
             State.ctx_expr(state),
             Builder.literal(atom_idx)
           ])
         )}

      {{:ok, name}, [idx]}
      when name in [:get_var_ref, :get_var_ref0, :get_var_ref1, :get_var_ref2, :get_var_ref3] ->
        {expr, state} = State.inline_get_var_ref(state, idx)
        {:ok, State.push(state, expr)}

      {{:ok, :get_var_ref_check}, [idx]} ->
        {expr, state} = State.inline_get_var_ref(state, idx)
        {:ok, State.push(state, expr)}

      {{:ok, name}, [idx]}
      when name in [
             :put_var_ref,
             :put_var_ref0,
             :put_var_ref1,
             :put_var_ref2,
             :put_var_ref3,
             :put_var_ref_check,
             :put_var_ref_check_init
           ] ->
        lower_put_var_ref(state, idx)

      {{:ok, name}, [idx]}
      when name in [:set_var_ref, :set_var_ref0, :set_var_ref1, :set_var_ref2, :set_var_ref3] ->
        lower_set_var_ref(state, idx)

      {{:ok, :make_loc_ref}, [atom_idx, var_idx]} ->
        lower_make_loc_ref(state, atom_idx, var_idx)

      {{:ok, :make_arg_ref}, [atom_idx, var_idx]} ->
        lower_make_arg_ref(state, atom_idx, var_idx)

      {{:ok, :make_var_ref}, [atom_idx]} ->
        lower_make_var_ref(state, atom_idx)

      {{:ok, :make_var_ref}, [atom_idx, var_idx]} ->
        lower_make_loc_ref(state, atom_idx, var_idx)

      {{:ok, :make_var_ref_ref}, [atom_idx, var_idx]} ->
        lower_make_var_ref_ref(state, atom_idx, var_idx)

      {{:ok, :get_ref_value}, []} ->
        lower_get_ref_value(state)

      {{:ok, :put_ref_value}, []} ->
        lower_put_ref_value(state)

      {{:ok, :delete_var}, [atom_idx]} ->
        {:ok,
         State.push(
           state,
           State.compiler_call(state, :delete_var, [Builder.literal(atom_idx)]),
           :boolean
         )}

      _ ->
        :not_handled
    end
  end

  defp lower_put_var(state, atom_idx) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      {:ok,
       State.update_ctx(
         state,
         Builder.remote_call(GlobalEnv, :put, [
           State.ctx_expr(state),
           Builder.literal(atom_idx),
           val
         ])
       )}
    end
  end

  defp lower_put_var_ref(state, idx) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      {:ok,
       %{
         state
         | body: [
             State.compiler_call(state, :put_var_ref, [Builder.literal(idx), val]) | state.body
           ]
       }}
    end
  end

  defp lower_set_var_ref(state, idx) do
    with {:ok, val, _type, state} <- State.pop_typed(state) do
      State.effectful_push(
        state,
        State.compiler_call(state, :set_var_ref, [Builder.literal(idx), val])
      )
    end
  end

  defp lower_make_loc_ref(state, atom_idx, idx) do
    ref = State.compiler_call(state, :make_loc_ref, [Builder.literal(idx)])
    key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> State.push(ref, :unknown) |> State.push(key, :string)}
  end

  defp lower_make_arg_ref(state, atom_idx, idx) do
    ref = State.compiler_call(state, :make_arg_ref, [Builder.literal(idx)])
    key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> State.push(ref, :unknown) |> State.push(key, :string)}
  end

  defp lower_make_var_ref(state, atom_idx) do
    ref = State.compiler_call(state, :make_var_ref, [Builder.literal(atom_idx)])
    key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> State.push(ref, :unknown) |> State.push(key, :string)}
  end

  defp lower_make_var_ref_ref(state, atom_idx, idx) do
    ref = State.compiler_call(state, :make_var_ref_ref, [Builder.literal(idx)])
    key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

    {:ok, state |> State.push(ref, :unknown) |> State.push(key, :string)}
  end

  defp lower_get_ref_value(state) do
    with {:ok, key, key_type, state} <- State.pop_typed(state),
         {:ok, ref, ref_type, state} <- State.pop_typed(state) do
      value = State.compiler_call(state, :get_ref_value, [key, ref])

      {:ok,
       %{
         state
         | stack: [value, key, ref | state.stack],
           stack_types: [:unknown, key_type, ref_type | state.stack_types]
       }}
    end
  end

  defp lower_put_ref_value(state) do
    with {:ok, val, state} <- State.pop(state),
         {:ok, key, state} <- State.pop(state),
         {:ok, ref, state} <- State.pop(state) do
      {:ok,
       %{
         state
         | body: [State.compiler_call(state, :put_ref_value, [val, key, ref]) | state.body]
       }}
    end
  end

  defp inline_get_var(state, name) do
    Builder.remote_call(RuntimeHelpers, :get_global, [
      {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :map_get}},
       [{:atom, 1, :globals}, State.ctx_expr(state)]},
      Builder.literal(name)
    ])
  end

  defp inline_get_var_undef(state, name) do
    Builder.remote_call(RuntimeHelpers, :get_global_undef, [
      {:call, 1, {:remote, 1, {:atom, 1, :erlang}, {:atom, 1, :map_get}},
       [{:atom, 1, :globals}, State.ctx_expr(state)]},
      Builder.literal(name)
    ])
  end
end
