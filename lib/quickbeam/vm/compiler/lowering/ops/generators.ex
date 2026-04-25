defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Generators do
  @moduledoc "Generator and async opcodes: initial_yield, yield, yield_star, async_yield_star, await, return_async."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers

  def lower(state, next_entry, stack_depths, name_args) do
    case name_args do
      {{:ok, :initial_yield}, []} ->
        yield_throw(state, Builder.atom(:undefined), next_entry, stack_depths)

      {{:ok, :yield}, []} ->
        with {:ok, val, _type, state} <- State.pop_typed(state) do
          yield_throw(state, val, next_entry, stack_depths)
        end

      {{:ok, :yield_star}, []} ->
        with {:ok, val, _type, state} <- State.pop_typed(state) do
          {:done,
           Enum.reverse([
             Builder.remote_call(:erlang, :throw, [
               Builder.tuple_expr([
                 Builder.atom(:generator_yield_star),
                 val,
                 yield_continuation(state, next_entry, stack_depths)
               ])
             ])
             | state.body
           ])}
        end

      {{:ok, :async_yield_star}, []} ->
        with {:ok, val, _type, state} <- State.pop_typed(state) do
          {:done,
           Enum.reverse([
             Builder.remote_call(:erlang, :throw, [
               Builder.tuple_expr([
                 Builder.atom(:generator_yield_star),
                 val,
                 yield_continuation(state, next_entry, stack_depths)
               ])
             ])
             | state.body
           ])}
        end

      {{:ok, :await}, []} ->
        with {:ok, val, _type, state} <- State.pop_typed(state) do
          State.effectful_push(
            state,
            Builder.remote_call(RuntimeHelpers, :await, [
              State.ctx_expr(state),
              val
            ])
          )
        end

      {{:ok, :return_async}, []} ->
        with {:ok, val, _state} <- State.pop(state) do
          {:done,
           Enum.reverse([
             Builder.remote_call(:erlang, :throw, [
               Builder.tuple_expr([Builder.atom(:generator_return), val])
             ])
             | state.body
           ])}
        end

      _ ->
        :not_handled
    end
  end

  defp yield_throw(state, val, next_entry, stack_depths) do
    {:done,
     Enum.reverse([
       Builder.remote_call(:erlang, :throw, [
         Builder.tuple_expr([
           Builder.atom(:generator_yield),
           val,
           yield_continuation(state, next_entry, stack_depths)
         ])
       ])
       | state.body
     ])}
  end

  defp yield_continuation(state, next_entry, stack_depths) do
    arg_var = Builder.var("YieldArg")
    false_var = Builder.atom(false)

    ctx = State.ctx_expr(state)
    slots = State.current_slots(state)
    stack = [false_var, arg_var | State.current_stack(state)]
    captures = State.current_capture_cells(state)

    expected_depth = Map.get(stack_depths, next_entry)

    if expected_depth && expected_depth == length(stack) do
      call =
        Builder.local_call(Builder.block_name(next_entry), [
          ctx | slots ++ stack ++ captures
        ])

      {:fun, 1, {:clauses, [{:clause, 1, [arg_var], [], [call]}]}}
    else
      {:fun, 1, {:clauses, [{:clause, 1, [arg_var], [], [Builder.atom(:undefined)]}]}}
    end
  end
end
