defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Locals do
  @moduledoc "Local and argument slot opcodes: get_loc, put_loc, set_loc, get_arg, put_arg, set_arg, etc."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}

  @tdz :__tdz__

  def lower(state, name_args) do
    case name_args do
      {{:ok, :get_arg}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg0}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg1}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg2}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_arg3}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc0}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc1}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc2}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc3}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc8}, [slot_idx]} ->
        {:ok,
         State.push(state, State.slot_expr(state, slot_idx), State.slot_type(state, slot_idx))}

      {{:ok, :get_loc0_loc1}, [slot0, slot1]} ->
        {:ok,
         %{
           state
           | stack: [State.slot_expr(state, slot1), State.slot_expr(state, slot0) | state.stack],
             stack_types: [
               State.slot_type(state, slot1),
               State.slot_type(state, slot0) | state.stack_types
             ]
         }}

      {{:ok, :get_loc_check}, [slot_idx]} ->
        lower_get_loc_check(state, slot_idx)

      {{:ok, :set_loc_uninitialized}, [slot_idx]} ->
        {:ok, State.put_uninitialized_slot(state, slot_idx, Builder.atom(@tdz))}

      {{:ok, :put_loc}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc8}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_arg3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :put_loc_check}, [slot_idx]} ->
        lower_put_loc_check(state, slot_idx)

      {{:ok, :put_loc_check_init}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, false)

      {{:ok, :set_loc}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc3}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_loc8}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg0}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg1}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg2}, [slot_idx]} ->
        State.assign_slot(state, slot_idx, true)

      {{:ok, :set_arg3}, [slot_idx]} ->
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

  defp lower_get_loc_check(state, slot_idx) do
    slot_expr = State.slot_expr(state, slot_idx)
    slot_type = State.slot_type(state, slot_idx)

    expr =
      if State.slot_initialized?(state, slot_idx) do
        slot_expr
      else
        State.compiler_call(state, :ensure_initialized_local!, [slot_expr])
      end

    {:ok, State.push(state, expr, slot_type)}
  end

  defp lower_put_loc_check(state, slot_idx) do
    wrapper =
      if State.slot_initialized?(state, slot_idx) do
        nil
      else
        :ensure_initialized_local!
      end

    State.assign_slot(state, slot_idx, false, wrapper)
  end
end
