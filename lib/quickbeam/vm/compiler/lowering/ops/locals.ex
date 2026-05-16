defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Locals do
  @moduledoc "Local and argument slot opcodes: get_loc, put_loc, set_loc, get_arg, put_arg, set_arg, etc."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  import QuickBEAM.VM.OpcodeFamily, only: [is_get_slot: 1, is_put_slot: 1, is_set_slot: 1]

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Captures, Slots, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  @tdz :__tdz__

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, name}, [slot_idx]} when is_get_slot(name) ->
        push_slot(state, slot_idx)

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok,
         %{
           state
           | stack: [Slots.slot_expr(state, slot1), Slots.slot_expr(state, slot0) | state.stack],
             stack_types: [
               Slots.slot_type(state, slot1),
               Slots.slot_type(state, slot0) | state.stack_types
             ]
         }}

      {{:ok, :get_loc_check}, [slot_idx]} ->
        lower_get_loc_check(state, slot_idx)

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, Slots.put_uninitialized_slot(state, slot_idx, Builder.atom(@tdz))}

      {{:ok, name}, [slot_idx]} when is_put_slot(name) ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc_check}, [slot_idx]} ->
        lower_put_loc_check(state, slot_idx)

      {{:ok, :put_loc_check_init}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, name}, [slot_idx]} when is_set_slot(name) ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :close_loc}, [slot_idx]} ->
        alias QuickBEAM.VM.Compiler.Lowering.Captures
        Captures.close_capture_cell(state, slot_idx)

      {{:ok, :inc_loc}, [slot_idx]} ->
        State.inc_slot(state, slot_idx)

      {{:ok, :dec_loc}, [slot_idx]} ->
        State.dec_slot(state, slot_idx)

      {{:ok, :add_loc}, [slot_idx]} ->
        State.add_to_slot(state, slot_idx)

      _ ->
        :not_handled
    end
  end

  defp push_slot(state, slot_idx) do
    expr = Slots.slot_expr(state, slot_idx)
    type = Slots.slot_type(state, slot_idx)

    value =
      if Captures.slot_captured?(state, slot_idx) do
        Builder.remote_call(RuntimeHelpers, :read_capture_cell, [
          Slots.capture_cell_expr(state, slot_idx),
          expr
        ])
      else
        expr
      end

    LoweringEffects.effectful_push(state, value, type)
  end

  defp lower_get_loc_check(state, slot_idx) do
    slot_expr = Slots.slot_expr(state, slot_idx)
    slot_type = Slots.slot_type(state, slot_idx)

    expr =
      if Slots.slot_initialized?(state, slot_idx) do
        slot_expr
      else
        State.compiler_call(state, :ensure_initialized_local!, [slot_expr])
      end

    value =
      if Captures.slot_captured?(state, slot_idx) do
        Builder.remote_call(RuntimeHelpers, :read_capture_cell, [
          Slots.capture_cell_expr(state, slot_idx),
          expr
        ])
      else
        expr
      end

    LoweringEffects.effectful_push(state, value, slot_type)
  end

  defp lower_put_loc_check(state, slot_idx) do
    wrapper =
      if Slots.slot_initialized?(state, slot_idx) do
        nil
      else
        :ensure_initialized_local!
      end

    State.assign_slot(state, slot_idx, false, wrapper)
  end
end
