defmodule QuickBEAM.VM.Compiler.Lowering.Ops.Iterators do
  @moduledoc "Iterator and for-in/of opcodes."

  alias QuickBEAM.VM.Compiler.Lowering.{Builder, State}
  alias QuickBEAM.VM.ObjectModel.Get

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
        with {:ok, obj, _type, state} <- State.pop_typed(state) do
          State.effectful_push(state, State.compiler_call(state, :for_of_start, [obj]))
        end

      {{:ok, :iterator_close}, []} ->
        lower_iterator_close(state)

      {{:ok, :iterator_check_object}, []} ->
        {:ok, state}

      {{:ok, :iterator_get_value_done}, []} ->
        with {:ok, result, state} <- State.pop(state) do
          done =
            Builder.remote_call(Get, :get, [
              result,
              Builder.literal("done")
            ])

          value =
            Builder.remote_call(Get, :get, [
              result,
              Builder.literal("value")
            ])

          {:ok, state |> State.push(done) |> State.push(value)}
        end

      {{:ok, :iterator_next}, []} ->
        with {:ok, iter, state} <- State.pop(state) do
          next_fn =
            Builder.remote_call(Get, :get, [
              iter,
              Builder.literal("next")
            ])

          State.effectful_push(
            state,
            Builder.remote_call(QuickBEAM.VM.Runtime, :call_callback, [
              next_fn,
              Builder.list_expr([])
            ])
          )
        end

      {{:ok, :iterator_call}, [_method]} ->
        with {:ok, iter, state} <- State.pop(state) do
          {:ok,
           State.emit(state, State.compiler_call(state, :iterator_close, [iter]))}
        end

      {{:ok, :rest}, [start_idx]} ->
        State.effectful_push(
          state,
          State.compiler_call(state, :rest, [Builder.literal(start_idx)]),
          :object
        )

      _ ->
        :not_handled
    end
  end

  defp lower_for_in_start(state) do
    with {:ok, obj, _type, state} <- State.pop_typed(state) do
      {:ok, State.push(state, State.compiler_call(state, :for_in_start, [obj]), :unknown)}
    end
  end

  defp lower_for_in_next(state) do
    case State.bind_stack_entry(state, 0) do
      {:ok, state, iter} ->
        {result, state} =
          State.bind(
            state,
            Builder.temp_name(state.temp),
            State.compiler_call(state, :for_in_next, [iter])
          )

        state = %{
          state
          | stack: List.replace_at(state.stack, 0, Builder.tuple_element(result, 3)),
            stack_types: List.replace_at(state.stack_types, 0, :unknown)
        }

        state = State.push(state, Builder.tuple_element(result, 2), :unknown)
        state = State.push(state, Builder.tuple_element(result, 1), :boolean)
        {:ok, state}

      :error ->
        {:error, :for_in_state_missing}
    end
  end

  defp lower_for_of_start(state) do
    with {:ok, obj, _type, state} <- State.pop_typed(state) do
      {pair, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          State.compiler_call(state, :for_of_start, [obj])
        )

      state = State.push(state, Builder.tuple_element(pair, 1), :object)
      state = State.push(state, Builder.tuple_element(pair, 2), :function)
      state = State.push(state, Builder.integer(0), :integer)
      {:ok, state}
    end
  end

  defp lower_for_of_next(state, iter_idx) do
    with {:ok, state, next_fn} <- State.bind_stack_entry(state, iter_idx + 1),
         {:ok, state, iter_obj} <- State.bind_stack_entry(state, iter_idx + 2) do
      {result, state} =
        State.bind(
          state,
          Builder.temp_name(state.temp),
          State.compiler_call(state, :for_of_next, [next_fn, iter_obj])
        )

      state = %{
        state
        | stack: List.replace_at(state.stack, iter_idx + 2, Builder.tuple_element(result, 3)),
          stack_types: List.replace_at(state.stack_types, iter_idx + 2, :object)
      }

      state = State.push(state, Builder.tuple_element(result, 2), :unknown)
      state = State.push(state, Builder.tuple_element(result, 1), :boolean)
      {:ok, state}
    else
      :error -> {:error, {:for_of_state_missing, iter_idx}}
    end
  end

  defp lower_iterator_close(state) do
    with {:ok, _catch_offset, _catch_type, state} <- State.pop_typed(state),
         {:ok, _next_fn, _next_type, state} <- State.pop_typed(state),
         {:ok, iter_obj, _iter_type, state} <- State.pop_typed(state) do
      {:ok,
       State.emit(state, State.compiler_call(state, :iterator_close, [iter_obj]))}
    end
  end
end
