defmodule QuickBEAM.VM.Compiler.Lowering.Ops.WithScope do
  @moduledoc "with-statement opcodes: with_get_var, with_put_var, with_delete_var, with_make_ref, with_get_ref, with_get_ref_undef."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    with_get_var: :with_get_var,
    with_get_ref: :with_get_ref,
    with_get_ref_undef: :with_get_ref_undef,
    with_put_var: :with_put_var,
    with_delete_var: :with_delete_var,
    with_make_ref: :with_make_ref
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :with_scope,
                        do: name

  if @invalid_handlers != [] do
    raise "with-scope lowering handlers registered for non-with-scope opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, next_entry, stack_depths, {{:ok, name}, [atom_idx, target, _is_with]}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      handler -> lower_handler(handler, state, next_entry, stack_depths, atom_idx, target)
    end
  end

  def lower(_state, _next_entry, _stack_depths, _name_args), do: :not_handled

  defp lower_handler(:with_get_var, state, next_entry, stack_depths, atom_idx, target),
    do: lower_with_get_var(state, next_entry, stack_depths, atom_idx, target)

  defp lower_handler(:with_get_ref, state, next_entry, stack_depths, atom_idx, target),
    do: lower_with_get_ref(state, next_entry, stack_depths, atom_idx, target)

  defp lower_handler(:with_get_ref_undef, state, next_entry, stack_depths, atom_idx, target),
    do: lower_with_get_ref_undef(state, next_entry, stack_depths, atom_idx, target)

  defp lower_handler(:with_put_var, state, next_entry, stack_depths, atom_idx, target),
    do: lower_with_put_var(state, next_entry, stack_depths, atom_idx, target)

  defp lower_handler(:with_delete_var, state, next_entry, stack_depths, atom_idx, target),
    do: lower_with_delete_var(state, next_entry, stack_depths, atom_idx, target)

  defp lower_handler(:with_make_ref, state, next_entry, stack_depths, atom_idx, target),
    do: lower_with_make_ref(state, next_entry, stack_depths, atom_idx, target)

  defp lower_with_get_var(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      val = State.abi_call(state, :get_field, [obj, key])
      target_state = Emit.push(state, val)

      branch_with_has_property(state, target_state, next_entry, stack_depths, obj, key, target)
    end
  end

  defp lower_with_put_var(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, next_state} <- Emit.pop(state),
         {:ok, val, target_state} <- Emit.pop(next_state),
         key = State.constant_call(next_state, :push_atom_value, [Builder.literal(atom_idx)]),
         {:ok, target_call} <- State.block_jump_call(target_state, target, stack_depths),
         {:ok, next_call} <- State.block_jump_call(next_state, next_entry, stack_depths) do
      condition = State.abi_call(next_state, :with_has_property, [obj, key])
      put = State.abi_call(next_state, :put_field, [obj, key, val])
      branch = Builder.branch_case(condition, [next_call], [put, target_call])

      {:done, Enum.reverse([branch | state.body])}
    end
  end

  defp lower_with_get_ref(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      val = State.abi_call(state, :get_field, [obj, key])
      target_state = state |> Emit.push(obj) |> Emit.push(val)

      branch_with_has_property(state, target_state, next_entry, stack_depths, obj, key, target)
    end
  end

  defp lower_with_get_ref_undef(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      val = State.abi_call(state, :get_field, [obj, key])
      target_state = state |> Emit.push(Builder.atom(:undefined), :undefined) |> Emit.push(val)

      branch_with_has_property(state, target_state, next_entry, stack_depths, obj, key, target)
    end
  end

  defp lower_with_delete_var(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, state} <- Emit.pop(state) do
      key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      target_state = Emit.push(state, Builder.atom(true), :boolean)
      delete = State.abi_call(state, :delete_property, [obj, key])
      condition = State.abi_call(state, :with_has_property, [obj, key])
      {:ok, target_call} = State.block_jump_call(target_state, target, stack_depths)
      {:ok, next_call} = State.block_jump_call(state, next_entry, stack_depths)
      branch = Builder.branch_case(condition, [next_call], [delete, target_call])
      {:done, Enum.reverse([branch | state.body])}
    end
  end

  defp lower_with_make_ref(state, next_entry, stack_depths, atom_idx, target) do
    with {:ok, obj, state} <- Emit.pop(state) do
      key = State.constant_call(state, :push_atom_value, [Builder.literal(atom_idx)])
      target_state = state |> Emit.push(obj, :object) |> Emit.push(key, :string)

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
      condition = State.abi_call(state, :with_has_property, [obj, key])

      body =
        Enum.reverse([Builder.branch_case(condition, [next_call], [target_call]) | state.body])

      {:done, body}
    end
  end
end
