defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Iterators do
  @moduledoc "Iterator and for-in/of opcodes."

  alias QuickBEAM.VM.Compiler.Lowering.Effects, as: LoweringEffects
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, State}
  alias QuickBEAM.VM.ObjectModel.Get

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(state, name_args) do
    case name_args do
      {{:ok, :for_in_start}, []} ->
        lower_for_in_start(state)

      {{:ok, :for_in_next}, []} ->
        lower_for_in_next(state)

      {{:ok, :for_of_start}, []} ->
        lower_for_of_start(state)

      {{:ok, :for_of_next}, [iter_idx]} ->
        lower_for_of_next(state, iter_idx)

      {{:ok, :for_await_of_start}, []} ->
        lower_for_await_of_start(state)

      {{:ok, :iterator_close}, []} ->
        lower_iterator_close(state)

      {{:ok, :iterator_check_object}, []} ->
        lower_iterator_check_object(state)

      {{:ok, :iterator_get_value_done}, []} ->
        with {:ok, result, state} <- Emit.pop(state) do
          {pair, state} =
            Emit.bind(
              state,
              Builder.temp_name(state.temp),
              State.abi_call(state, :iterator_value_done, [result])
            )

          {:ok,
           state
           |> Emit.push(Builder.tuple_element(pair, 1))
           |> Emit.push(Builder.tuple_element(pair, 2))}
        end

      {{:ok, :iterator_next}, []} ->
        lower_iterator_next(state)

      {{:ok, :iterator_call}, [flags]} ->
        lower_iterator_call(state, flags)

      {{:ok, :rest}, [start_idx]} ->
        LoweringEffects.effectful_push(
          state,
          State.compiler_call(state, :rest, [Builder.literal(start_idx)]),
          :object
        )

      _ ->
        :not_handled
    end
  end

  defp lower_iterator_call(
         %{
           stack: [val, catch_offset, next_fn, iter_obj | rest],
           stack_types: [val_type, catch_type, next_type, iter_type | type_rest]
         } = state,
         flags
       ) do
    {tuple, state} =
      Emit.bind(
        state,
        Builder.temp_name(state.temp),
        State.abi_call(state, :iterator_call, [
          Builder.literal(flags),
          val,
          catch_offset,
          next_fn,
          iter_obj
        ])
      )

    {:ok,
     %{
       state
       | stack: [
           Builder.tuple_element(tuple, 1),
           Builder.tuple_element(tuple, 2),
           Builder.tuple_element(tuple, 3),
           Builder.tuple_element(tuple, 4),
           Builder.tuple_element(tuple, 5) | rest
         ],
         stack_types: [:boolean, val_type, catch_type, next_type, iter_type | type_rest]
     }}
  end

  defp lower_iterator_call(_state, _flags), do: {:error, :iterator_call_state_missing}

  defp lower_iterator_check_object(state) do
    with {:ok, value, type, state} <- Emit.pop_typed(state) do
      if type == :object do
        {:ok, Emit.push(state, value, type)}
      else
        LoweringEffects.effectful_push(
          state,
          State.abi_call(state, :iterator_check_object, [value]),
          :object
        )
      end
    end
  end

  defp lower_iterator_next(
         %{
           stack: [val, catch_offset, next_fn, iter_obj | rest],
           stack_types: [_val_type, catch_type, next_type, iter_type | type_rest]
         } = state
       ) do
    {pair, state} =
      Emit.bind(
        state,
        Builder.temp_name(state.temp),
        State.abi_call(state, :iterator_next_result, [next_fn, iter_obj, val])
      )

    {:ok,
     %{
       state
       | stack: [
           Builder.tuple_element(pair, 1),
           catch_offset,
           next_fn,
           Builder.tuple_element(pair, 2) | rest
         ],
         stack_types: [:object, catch_type, next_type, iter_type | type_rest]
     }}
  end

  defp lower_iterator_next(state) do
    with {:ok, iter, state} <- Emit.pop(state) do
      next_fn =
        Builder.remote_call(Get, :get, [
          iter,
          Builder.literal("next")
        ])

      LoweringEffects.effectful_push(
        state,
        Builder.remote_call(QuickBEAM.VM.Runtime, :call_callback, [
          next_fn,
          Builder.list_expr([])
        ])
      )
    end
  end

  defp lower_for_await_of_start(state) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :for_of_start, [obj])
        )

      {:ok,
       %{
         state
         | stack: [
             Builder.integer(0),
             Builder.tuple_element(pair, 2),
             Builder.tuple_element(pair, 1) | state.stack
           ],
           stack_types: [:integer, :function, :object | state.stack_types]
       }}
    end
  end

  defp lower_for_in_start(state) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      {:ok, Emit.push(state, State.abi_call(state, :for_in_start, [obj]), :unknown)}
    end
  end

  defp lower_for_in_next(state) do
    case Emit.bind_stack_entry(state, 0) do
      {:ok, state, iter} ->
        {result, state} =
          Emit.bind(
            state,
            Builder.temp_name(state.temp),
            State.abi_call(state, :for_in_next, [iter])
          )

        state = %{
          state
          | stack: List.replace_at(state.stack, 0, Builder.tuple_element(result, 3)),
            stack_types: List.replace_at(state.stack_types, 0, :unknown)
        }

        state = Emit.push(state, Builder.tuple_element(result, 2), :unknown)
        state = Emit.push(state, Builder.tuple_element(result, 1), :boolean)
        {:ok, state}

      :error ->
        {:error, :for_in_state_missing}
    end
  end

  defp lower_for_of_start(state) do
    with {:ok, obj, _type, state} <- Emit.pop_typed(state) do
      {pair, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :for_of_start, [obj])
        )

      state = Emit.push(state, Builder.tuple_element(pair, 1), :object)
      state = Emit.push(state, Builder.tuple_element(pair, 2), :function)
      state = Emit.push(state, Builder.integer(0), :integer)
      {:ok, state}
    end
  end

  defp lower_for_of_next(state, iter_idx) do
    with {:ok, state, next_fn} <- Emit.bind_stack_entry(state, iter_idx + 1),
         {:ok, state, iter_obj} <- Emit.bind_stack_entry(state, iter_idx + 2) do
      {result, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :for_of_next, [next_fn, iter_obj])
        )

      state = %{
        state
        | stack: List.replace_at(state.stack, iter_idx + 2, Builder.tuple_element(result, 3)),
          stack_types: List.replace_at(state.stack_types, iter_idx + 2, :object)
      }

      state = Emit.push(state, Builder.tuple_element(result, 2), :unknown)
      state = Emit.push(state, Builder.tuple_element(result, 1), :boolean)
      {:ok, state}
    else
      :error -> {:error, {:for_of_state_missing, iter_idx}}
    end
  end

  defp lower_iterator_close(state) do
    with {:ok, _catch_offset, _catch_type, state} <- Emit.pop_typed(state),
         {:ok, _next_fn, _next_type, state} <- Emit.pop_typed(state),
         {:ok, iter_obj, _iter_type, state} <- Emit.pop_typed(state) do
      state = State.update_ctx(state, State.abi_call(state, :iterator_close_refresh, [iter_obj]))
      {:ok, state}
    end
  end
end
