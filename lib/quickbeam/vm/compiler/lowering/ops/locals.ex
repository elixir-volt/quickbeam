defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Locals do
  @moduledoc "Local and argument slot opcodes: get_loc, put_loc, set_loc, get_arg, put_arg, set_arg, etc."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Captures, Slots, State}
  alias QuickBEAM.VM.OpcodeSpec

  @tdz :__tdz__

  @handlers %{
    get_arg: :get_slot,
    get_arg0: :get_slot,
    get_arg1: :get_slot,
    get_arg2: :get_slot,
    get_arg3: :get_slot,
    get_loc: :get_slot,
    get_loc0: :get_slot,
    get_loc1: :get_slot,
    get_loc2: :get_slot,
    get_loc3: :get_slot,
    get_loc8: :get_slot,
    put_arg: :put_slot,
    put_arg0: :put_slot,
    put_arg1: :put_slot,
    put_arg2: :put_slot,
    put_arg3: :put_slot,
    put_loc: :put_slot,
    put_loc0: :put_slot,
    put_loc1: :put_slot,
    put_loc2: :put_slot,
    put_loc3: :put_slot,
    put_loc8: :put_slot,
    set_arg: :set_slot,
    set_arg0: :set_slot,
    set_arg1: :set_slot,
    set_arg2: :set_slot,
    set_arg3: :set_slot,
    set_loc: :set_slot,
    set_loc0: :set_slot,
    set_loc1: :set_slot,
    set_loc2: :set_slot,
    set_loc3: :set_slot,
    set_loc8: :set_slot,
    get_loc0_loc1: :get_loc0_loc1,
    get_loc_check: :get_loc_check,
    set_loc_uninitialized: :set_loc_uninitialized,
    put_loc_check: :put_loc_check,
    put_loc_check_init: :put_loc_check_init,
    close_loc: :close_loc,
    inc_loc: :inc_loc,
    dec_loc: :dec_loc,
    add_loc: :add_loc
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :locals,
                        do: name

  if @invalid_handlers != [] do
    raise "locals lowering handlers registered for non-local opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, name}, args} ->
        case Map.get(@handlers, name) do
          nil -> :not_handled
          handler -> lower_handler(handler, state, args)
        end

      _ ->
        :not_handled
    end
  end

  defp lower_handler(:get_slot, state, [slot_idx]), do: push_slot(state, slot_idx)

  defp lower_handler(:get_loc0_loc1, state, [slot0, slot1]) do
    {:ok,
     %{
       state
       | stack: [Slots.slot_expr(state, slot1), Slots.slot_expr(state, slot0) | state.stack],
         stack_types: [
           Slots.slot_type(state, slot1),
           Slots.slot_type(state, slot0) | state.stack_types
         ]
     }}
  end

  defp lower_handler(:get_loc_check, state, [slot_idx]), do: lower_get_loc_check(state, slot_idx)

  defp lower_handler(:set_loc_uninitialized, state, [slot_idx]),
    do: {:ok, Slots.put_uninitialized_slot(state, slot_idx, Builder.atom(@tdz))}

  defp lower_handler(:put_slot, state, [slot_idx]), do: State.assign_slot(state, slot_idx, false)
  defp lower_handler(:put_loc_check, state, [slot_idx]), do: lower_put_loc_check(state, slot_idx)

  defp lower_handler(:put_loc_check_init, state, [slot_idx]) do
    wrapper =
      if local_name(state, slot_idx) == "this" do
        {:ensure_uninitialized_this!, Slots.slot_expr(state, slot_idx)}
      end

    State.assign_slot(state, slot_idx, false, wrapper)
  end

  defp lower_handler(:set_slot, state, [slot_idx]), do: State.assign_slot(state, slot_idx, true)

  defp lower_handler(:close_loc, state, [slot_idx]),
    do: Captures.close_capture_cell(state, slot_idx)

  defp lower_handler(:inc_loc, state, [slot_idx]), do: State.inc_slot(state, slot_idx)
  defp lower_handler(:dec_loc, state, [slot_idx]), do: State.dec_slot(state, slot_idx)
  defp lower_handler(:add_loc, state, [slot_idx]), do: State.add_to_slot(state, slot_idx)
  defp lower_handler(_handler, _state, _args), do: :not_handled

  defp push_slot(state, slot_idx) do
    expr = Slots.slot_expr(state, slot_idx)
    type = Slots.slot_type(state, slot_idx)

    value =
      if Captures.slot_captured?(state, slot_idx) do
        State.abi_call(state, :read_capture_cell, [Slots.capture_cell_expr(state, slot_idx), expr])
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
        State.abi_call(state, :ensure_initialized_local!, [slot_expr])
      end

    value =
      if Captures.slot_captured?(state, slot_idx) do
        State.abi_call(state, :read_capture_cell, [Slots.capture_cell_expr(state, slot_idx), expr])
      else
        expr
      end

    LoweringEffects.effectful_push(state, value, slot_type)
  end

  defp local_name(%{locals: locals}, slot_idx) when is_list(locals) and slot_idx < length(locals),
    do: locals |> Enum.at(slot_idx) |> Map.get(:name) |> QuickBEAM.VM.Names.resolve_display_name()

  defp local_name(_, _), do: nil

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
