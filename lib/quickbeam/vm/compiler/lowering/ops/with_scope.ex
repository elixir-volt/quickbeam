defmodule QuickBEAM.VM.Compiler.Lowering.Ops.WithScope do
  @moduledoc "with-statement opcodes: with_get_var, with_put_var, with_delete_var, with_make_ref, with_get_ref, with_get_ref_undef."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.ObjectModel.{Delete, Get, Put}

  @doc "Lowers a bytecode instruction or function into compiler IR."
  def lower(state, next_entry, stack_depths, name_args) do
    case name_args do
      {{:ok, :with_get_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, _type, state} <- State.pop_typed(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          val = Builder.remote_call(Get, :get, [obj, key])

          {:ok, State.push(state, val)}
        end

      {{:ok, :with_get_ref}, [atom_idx, target, _is_with]} ->
        lower_with_get_ref(state, next_entry, stack_depths, atom_idx, target)

      {{:ok, :with_get_ref_undef}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, _type, state} <- State.pop_typed(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          val = Builder.remote_call(Get, :get, [obj, key])

          {:ok, state |> State.push(Builder.atom(:undefined)) |> State.push(val)}
        end

      {{:ok, :with_put_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state),
             {:ok, val, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

          {:ok, State.emit(state, Builder.remote_call(Put, :put, [obj, key, val]))}
        end

      {{:ok, :with_delete_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

          State.effectful_push(
            state,
            Builder.remote_call(Delete, :delete_property, [obj, key])
          )
        end

      {{:ok, :with_make_ref}, [atom_idx, target, _is_with]} ->
        lower_with_make_ref(state, next_entry, stack_depths, atom_idx, target)

      _ ->
        :not_handled
    end
  end

  defp lower_with_get_ref(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, _type, state} <- State.pop_typed(state) do
      key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      val = Builder.remote_call(Get, :get, [obj, key])
      target_state = state |> State.push(obj) |> State.push(val)

      branch_with_has_property(state, target_state, next_entry, stack_depths, obj, key, target)
    end
  end

  defp lower_with_make_ref(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, state} <- State.pop(state) do
      key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      target_state = state |> State.push(obj, :object) |> State.push(key, :string)

      branch_with_has_property(state, target_state, next_entry, stack_depths, obj, key, target)
    end
  end

  defp branch_with_has_property(state, target_state, next_entry, stack_depths, obj, key, target) do
    branch_with_has_property(
      state,
      target_state,
      state,
      next_entry,
      stack_depths,
      obj,
      key,
      target
    )
  end

  defp branch_with_has_property(
         state,
         target_state,
         next_state,
         next_entry,
         stack_depths,
         obj,
         key,
         target
       ) do
    with {:ok, target_call} <- State.block_jump_call(target_state, target, stack_depths),
         {:ok, next_call} <- State.block_jump_call(next_state, next_entry, stack_depths) do
      condition = State.compiler_call(state, :with_has_property, [obj, key])

      body =
        Enum.reverse([Builder.branch_case(condition, [next_call], [target_call]) | state.body])

      {:done, body}
    end
  end
end
