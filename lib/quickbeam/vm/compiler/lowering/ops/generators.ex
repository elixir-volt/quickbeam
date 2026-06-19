defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Generators do
  @moduledoc "Generator and async opcodes: initial_yield, yield, yield_star, async_yield_star, await, return_async."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, Slots, State}
  alias QuickBEAM.VM.OpcodeSpec

  @handlers %{
    initial_yield: :initial_yield,
    yield: :yield,
    yield_star: :yield_star,
    async_yield_star: :yield_star,
    await: :await,
    return_async: :return_async
  }

  @invalid_handlers for {name, _handler} <- @handlers,
                        OpcodeSpec.lowering_family(name) != :generators,
                        do: name

  if @invalid_handlers != [] do
    raise "generator lowering handlers registered for non-generator opcodes: #{inspect(@invalid_handlers)}"
  end

  def registered_opcodes, do: Map.keys(@handlers)
  def handler_for(name), do: Map.get(@handlers, name)

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, next_entry, stack_depths, {{:ok, name}, args}) do
    case Map.get(@handlers, name) do
      nil -> :not_handled
      handler -> lower_handler(handler, state, next_entry, stack_depths, args)
    end
  end

  def lower(_state, _next_entry, _stack_depths, _name_args), do: :not_handled

  defp lower_handler(:initial_yield, state, next_entry, stack_depths, []),
    do: initial_yield_throw(state, next_entry, stack_depths)

  defp lower_handler(:yield, state, next_entry, stack_depths, []) do
    with {:ok, val, _type, state} <- Emit.pop_typed(state) do
      yield_throw(state, val, next_entry, stack_depths)
    end
  end

  defp lower_handler(:yield_star, state, next_entry, _stack_depths, []) do
    with {:ok, val, _type, state} <- Emit.pop_typed(state) do
      {:done,
       Enum.reverse([
         Builder.remote_call(:erlang, :throw, [
           Builder.tuple_expr([
             Builder.atom(:generator_yield_star),
             val,
             yield_star_continuation(state, next_entry)
           ])
         ])
         | state.body
       ])}
    end
  end

  defp lower_handler(:await, state, _next_entry, _stack_depths, []) do
    with {:ok, val, _type, state} <- Emit.pop_typed(state) do
      LoweringEffects.effectful_push(state, State.abi_call(state, :await, [val]))
    end
  end

  defp lower_handler(:return_async, state, _next_entry, _stack_depths, []) do
    with {:ok, val, _state} <- Emit.pop(state) do
      {:done,
       Enum.reverse([
         Builder.remote_call(:erlang, :throw, [
           Builder.tuple_expr([Builder.atom(:generator_return), val])
         ])
         | state.body
       ])}
    end
  end

  defp lower_handler(_handler, _state, _next_entry, _stack_depths, _args), do: :not_handled

  defp initial_yield_throw(state, next_entry, stack_depths) do
    {:done,
     Enum.reverse([
       Builder.remote_call(:erlang, :throw, [
         Builder.tuple_expr([
           Builder.atom(:generator_yield),
           Builder.atom(:undefined),
           initial_yield_continuation(state, next_entry, stack_depths)
         ])
       ])
       | state.body
     ])}
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

  defp initial_yield_continuation(state, next_entry, stack_depths) do
    arg_var = Builder.var("YieldArg")
    ctx = State.ctx_expr(state)
    slots = Slots.current_slots(state)
    stack = State.current_stack(state)
    captures = Slots.current_capture_cells(state)

    continuation_fun(arg_var, ctx, slots, stack, captures, next_entry, stack_depths)
  end

  defp continuation_fun(arg_var, ctx, slots, stack, captures, next_entry, stack_depths) do
    expected_depth = Map.get(stack_depths, next_entry)

    if expected_depth && expected_depth == length(stack) do
      call =
        Builder.local_call(Builder.block_name(next_entry), [
          ctx | slots ++ stack ++ captures
        ])

      Builder.anonymous_fun([arg_var], [], [call])
    else
      Builder.anonymous_fun([arg_var], [], [Builder.atom(:undefined)])
    end
  end

  defp yield_star_continuation(state, next_entry) do
    arg_var = Builder.var("YieldArg")
    false_var = Builder.atom(false)

    ctx = State.ctx_expr(state)
    slots = Slots.current_slots(state)
    stack = [false_var, arg_var | State.current_stack(state)]
    captures = Slots.current_capture_cells(state)

    call =
      Builder.local_call(Builder.block_name(next_entry), [
        ctx | slots ++ stack ++ captures
      ])

    Builder.anonymous_fun([arg_var], [], [call])
  end

  defp yield_continuation(state, next_entry, stack_depths) do
    arg_var = Builder.var("YieldArg")

    ctx = State.ctx_expr(state)
    slots = Slots.current_slots(state)
    stack = resume_stack(arg_var, state)
    captures = Slots.current_capture_cells(state)

    continuation_fun(arg_var, ctx, slots, stack, captures, next_entry, stack_depths)
  end

  defp resume_stack(arg_var, state) do
    [
      State.abi_call(state, :generator_resume_return?, [arg_var]),
      State.abi_call(state, :generator_resume_value, [arg_var])
      | State.current_stack(state)
    ]
  end
end
