defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Calls do
  @moduledoc "Call, apply, eval, return, and closure opcodes."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Captures, Emit, Slots, State}
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    call: :call,
    call0: :call,
    call1: :call,
    call2: :call,
    call3: :call,
    call_constructor: :call_constructor,
    tail_call: :tail_call,
    call_method: :call_method,
    tail_call_method: :tail_call_method,
    apply: :apply,
    apply_eval: :apply_eval,
    eval: :eval,
    import: :import,
    return: :return,
    return_undef: :return_undef
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :calls,
                        do: name

  if @invalid_handlers != [] do
    raise "call lowering handlers registered for non-call opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, idx, {{:ok, name}, args}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      :call -> lower_call_handler(state, name, args)
      handler -> lower_handler(handler, state, idx, args)
    end
  end

  def lower(_state, _idx, _name_args), do: :not_handled

  defp lower_handler(:call_constructor, state, idx, [argc]),
    do: State.invoke_constructor_call(state, argc, idx)

  defp lower_handler(:tail_call, state, _idx, [argc]), do: State.invoke_tail_call(state, argc)
  defp lower_handler(:call_method, state, _idx, [argc]), do: State.invoke_method_call(state, argc)

  defp lower_handler(:tail_call_method, state, _idx, [argc]),
    do: State.invoke_tail_method_call(state, argc)

  defp lower_handler(:apply, state, _idx, [1]) do
    with {:ok, arg_array, state} <- Emit.pop(state),
         {:ok, new_target, state} <- Emit.pop(state),
         {:ok, fun, state} <- Emit.pop(state) do
      {result, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :apply_super, [
            fun,
            new_target,
            State.abi_call(state, :to_list, [arg_array])
          ])
        )

      state = State.update_ctx(state, State.abi_call(state, :update_this, [result]))

      {:ok, Emit.push(state, result)}
    end
  end

  defp lower_handler(:apply, state, _idx, [_magic]) do
    with {:ok, arg_array, state} <- Emit.pop(state),
         {:ok, this_obj, state} <- Emit.pop(state),
         {:ok, fun, state} <- Emit.pop(state) do
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :invoke_method_runtime, [
          fun,
          this_obj,
          State.abi_call(state, :to_list, [arg_array])
        ])
      )
    end
  end

  defp lower_handler(:apply_eval, state, _idx, [_scope_idx]) do
    with {:ok, arg_array, state} <- Emit.pop(state),
         {:ok, fun, state} <- Emit.pop(state),
         {:ok, state} <- ensure_eval_capture_cells(state) do
      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :eval_or_call_scope, [
          fun,
          State.abi_call(state, :to_list, [arg_array]),
          Builder.literal(state.locals),
          Builder.list_expr(Slots.current_capture_cells(state))
        ])
      )
    end
  end

  defp lower_handler(:eval, state, _idx, [argc | _scope_args]) do
    with {:ok, args, _types, state} <- Emit.pop_n_typed(state, argc + 1),
         {:ok, state} <- ensure_eval_capture_cells(state) do
      [eval_ref | call_args] = Enum.reverse(args)

      LoweringEffects.effectful_push(
        state,
        State.abi_call(state, :eval_or_call_scope, [
          eval_ref,
          Builder.list_expr(call_args),
          Builder.literal(state.locals),
          Builder.list_expr(Slots.current_capture_cells(state))
        ])
      )
    end
  end

  defp lower_handler(:import, state, _idx, []) do
    with {:ok, _meta, state} <- Emit.pop(state),
         {:ok, specifier, state} <- Emit.pop(state) do
      LoweringEffects.effectful_push(state, State.abi_call(state, :import_module, [specifier]))
    end
  end

  defp lower_handler(:return, state, _idx, []), do: State.return_top(state)

  defp lower_handler(:return_undef, state, _idx, []),
    do: {:done, Enum.reverse([Builder.atom(:undefined) | state.body])}

  defp lower_handler(_handler, _state, _idx, _args), do: :not_handled

  defp lower_call_handler(state, name, args) do
    case OpcodeSpec.call_arity(name, args) do
      {:ok, argc} -> State.invoke_call(state, argc)
      :error -> :not_handled
    end
  end

  defp ensure_eval_capture_cells(state) do
    state.locals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {_local, idx}, {:ok, state} ->
      if Captures.slot_captured?(state, idx) do
        case Captures.ensure_capture_cell(state, idx) do
          {:ok, state, _cell} -> {:cont, {:ok, state}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, state}}
      end
    end)
  end
end
