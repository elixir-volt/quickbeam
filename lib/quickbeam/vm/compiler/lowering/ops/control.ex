defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Control do
  @moduledoc "Control flow opcodes: if_true, if_false, goto, catch, nip_catch, throw, throw_error, gosub, ret."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    if_false: {:branch, false},
    if_false8: {:branch, false},
    if_true: {:branch, true},
    if_true8: {:branch, true},
    goto: :goto,
    goto8: :goto,
    goto16: :goto,
    nip_catch: :nip_catch,
    throw: :throw,
    throw_error: :throw_error,
    gosub: :gosub,
    ret: :ret,
    catch: :catch
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :control,
                        do: name

  if @invalid_handlers != [] do
    raise "control lowering handlers registered for non-control opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, idx, next_entry, stack_depths, inline_targets, {{:ok, name}, args}) do
    case OpcodeSpec.branch_target(name, args) do
      {:ok, {:branch, sense, target}} ->
        State.branch(state, idx, next_entry, target, sense, stack_depths)

      {:ok, {:goto, target}} ->
        lower_goto(state, target, stack_depths, inline_targets)

      :error ->
        case Map.get(@handlers, name) do
          nil ->
            :not_handled

          handler ->
            lower_handler(handler, state, idx, next_entry, stack_depths, inline_targets, args)
        end
    end
  end

  def lower(_state, _idx, _next_entry, _stack_depths, _inline_targets, _name_args),
    do: :not_handled

  defp lower_handler(:nip_catch, state, _idx, _next_entry, _stack_depths, _inline_targets, []),
    do: Emit.nip_catch(state)

  defp lower_handler(:throw, state, _idx, _next_entry, _stack_depths, _inline_targets, []),
    do: State.throw_top(state)

  defp lower_handler(:throw_error, state, _idx, _next_entry, _stack_depths, _inline_targets, [
         atom_idx,
         reason
       ]) do
    {:done,
     Enum.reverse([
       State.abi_call(state, :throw_error, [Builder.literal(atom_idx), Builder.literal(reason)])
       | state.body
     ])}
  end

  defp lower_handler(:gosub, state, _idx, _next_entry, stack_depths, _inline_targets, [target]),
    do: State.goto(state, target, stack_depths)

  defp lower_handler(:ret, state, _idx, _next_entry, _stack_depths, _inline_targets, []),
    do: {:done, Enum.reverse([Builder.atom(:undefined) | state.body])}

  defp lower_handler(:catch, state, _idx, _next_entry, _stack_depths, _inline_targets, [_target]),
    do: {:ok, Emit.push(state, Builder.integer(0))}

  defp lower_handler(_handler, _state, _idx, _next_entry, _stack_depths, _inline_targets, _args),
    do: :not_handled

  defp lower_goto(state, target, stack_depths, inline_targets) do
    if MapSet.member?(inline_targets, target) do
      {:inline_goto, target, state}
    else
      State.goto(state, target, stack_depths)
    end
  end
end
