defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Calls do
  @moduledoc "Call, apply, eval, return, and closure opcodes."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  import QuickBEAM.VM.OpcodeFamily, only: [is_call: 1]

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, idx, name_args) do
    case name_args do
      {{:ok, :call_constructor}, [argc]} ->
        State.invoke_constructor_call(state, argc, idx)

      {{:ok, name}, [argc]} when is_call(name) ->
        State.invoke_call(state, argc)

      {{:ok, :tail_call}, [argc]} ->
        State.invoke_tail_call(state, argc)

      {{:ok, :call_method}, [argc]} ->
        State.invoke_method_call(state, argc)

      {{:ok, :tail_call_method}, [argc]} ->
        State.invoke_tail_method_call(state, argc)

      {{:ok, :apply}, [1]} ->
        with {:ok, arg_array, state} <- Emit.pop(state),
             {:ok, new_target, state} <- Emit.pop(state),
             {:ok, fun, state} <- Emit.pop(state) do
          {result, state} =
            Emit.bind(
              state,
              Builder.temp_name(state.temp),
              State.compiler_call(state, :apply_super, [
                fun,
                new_target,
                Builder.remote_call(QuickBEAM.VM.Heap, :to_list, [arg_array])
              ])
            )

          state =
            State.update_ctx(
              state,
              State.compiler_call(state, :update_this, [result])
            )

          {:ok, Emit.push(state, result)}
        end

      {{:ok, :apply}, [_magic]} ->
        with {:ok, arg_array, state} <- Emit.pop(state),
             {:ok, this_obj, state} <- Emit.pop(state),
             {:ok, fun, state} <- Emit.pop(state) do
          LoweringEffects.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_method_runtime, [
              State.ctx_expr(state),
              fun,
              this_obj,
              Builder.remote_call(QuickBEAM.VM.Heap, :to_list, [arg_array])
            ])
          )
        end

      {{:ok, :apply_eval}, [_scope_idx]} ->
        with {:ok, arg_array, state} <- Emit.pop(state),
             {:ok, fun, state} <- Emit.pop(state) do
          LoweringEffects.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.Invocation, :invoke_runtime, [
              State.ctx_expr(state),
              fun,
              Builder.remote_call(QuickBEAM.VM.Heap, :to_list, [arg_array])
            ])
          )
        end

      {{:ok, :eval}, [argc | _scope_args]} ->
        with {:ok, args, _types, state} <- Emit.pop_n_typed(state, argc + 1) do
          [eval_ref | call_args] = Enum.reverse(args)

          LoweringEffects.effectful_push(
            state,
            State.compiler_call(state, :eval_or_call, [eval_ref, Builder.list_expr(call_args)])
          )
        end

      {{:ok, :import}, []} ->
        with {:ok, _meta, state} <- Emit.pop(state),
             {:ok, specifier, state} <- Emit.pop(state) do
          LoweringEffects.effectful_push(
            state,
            State.compiler_call(state, :import_module, [specifier])
          )
        end

      {{:ok, :return}, []} ->
        State.return_top(state)

      {{:ok, :return_undef}, []} ->
        {:done, Enum.reverse([Builder.atom(:undefined) | state.body])}

      _ ->
        :not_handled
    end
  end
end
