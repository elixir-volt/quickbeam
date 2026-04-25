defmodule QuickBEAM.VM.Compiler.Lowering.Ops.WithScope do
  @moduledoc "with-statement opcodes: with_get_var, with_put_var, with_delete_var, with_make_ref, with_get_ref, with_get_ref_undef."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.ObjectModel.{Delete, Get, Put}

  def lower(state, name_args) do
    case name_args do
      {{:ok, name}, [atom_idx, _target, _is_with]}
      when name in [:with_get_var, :with_get_ref, :with_get_ref_undef] ->
        with {:ok, obj, _type, state} <- State.pop_typed(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])
          val = Builder.remote_call(Get, :get, [obj, key])

          case name do
            :with_get_var ->
              {:ok, State.push(state, val)}

            :with_get_ref ->
              {:ok, state |> State.push(obj) |> State.push(val)}

            :with_get_ref_undef ->
              {:ok, state |> State.push(Builder.atom(:undefined)) |> State.push(val)}
          end
        end

      {{:ok, :with_put_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state),
             {:ok, val, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

          {:ok,
           State.emit(state, Builder.remote_call(Put, :put, [obj, key, val]))}
        end

      {{:ok, :with_delete_var}, [atom_idx, _target, _is_with]} ->
        with {:ok, obj, state} <- State.pop(state) do
          key = State.compiler_call(state, :push_atom_value, [Builder.literal(atom_idx)])

          State.effectful_push(
            state,
            Builder.remote_call(Delete, :delete_property, [obj, key])
          )
        end

      {{:ok, :with_make_ref}, _args} ->
        {:error, {:unsupported_opcode, :with_make_ref}}

      _ ->
        :not_handled
    end
  end
end
