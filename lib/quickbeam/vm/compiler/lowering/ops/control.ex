defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Control do
  @moduledoc "Control flow opcodes: if_true, if_false, goto, catch, nip_catch, throw, throw_error, gosub, ret."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}

  def lower(state, idx, next_entry, stack_depths, inline_targets, name_args) do
    case name_args do
      {{:ok, :if_false}, [target]} ->
        State.branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_false8}, [target]} ->
        State.branch(state, idx, next_entry, target, false, stack_depths)

      {{:ok, :if_true}, [target]} ->
        State.branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :if_true8}, [target]} ->
        State.branch(state, idx, next_entry, target, true, stack_depths)

      {{:ok, :goto}, [target]} ->
        lower_goto(state, target, stack_depths, inline_targets)

      {{:ok, :goto8}, [target]} ->
        lower_goto(state, target, stack_depths, inline_targets)

      {{:ok, :goto16}, [target]} ->
        lower_goto(state, target, stack_depths, inline_targets)

      {{:ok, :nip_catch}, []} ->
        State.nip_catch(state)

      {{:ok, :throw}, []} ->
        State.throw_top(state)

      {{:ok, :throw_error}, [atom_idx, reason]} ->
        {:done,
         Enum.reverse([
           State.compiler_call(state, :throw_error, [
             Builder.literal(atom_idx),
             Builder.literal(reason)
           ])
           | state.body
         ])}

      {{:ok, :gosub}, [target]} ->
        State.goto(state, target, stack_depths)

      {{:ok, :ret}, []} ->
        {:done, Enum.reverse([Builder.atom(:undefined) | state.body])}

      {{:ok, :catch}, [_target]} ->
        {:ok, State.push(state, Builder.integer(0))}

      _ ->
        :not_handled
    end
  end

  defp lower_goto(state, target, stack_depths, inline_targets) do
    if MapSet.member?(inline_targets, target) do
      {:inline_goto, target, state}
    else
      State.goto(state, target, stack_depths)
    end
  end
end
