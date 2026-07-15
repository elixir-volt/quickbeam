defmodule QuickBEAM.VM.StackVerifier do
  @moduledoc """
  Verifies QuickJS operand-stack dataflow over decoded instruction indexes.

  This mirrors QuickJS's `compute_stack_size`: every reachable instruction has
  one consistent stack depth and active catch target, variable-arity calls add
  their encoded pop count, and exceptional/control-flow edges receive their
  opcode-specific stack depth.
  """

  alias QuickBEAM.VM.{Function, Opcodes}

  @terminal_ops [
    :tail_call,
    :tail_call_method,
    :return,
    :return_undef,
    :return_async,
    :throw,
    :throw_error,
    :ret
  ]
  @goto_ops [:goto, :goto8, :goto16]
  @conditional_ops [:if_true, :if_true8, :if_false, :if_false8]
  @with_one_ops [:with_get_var, :with_delete_var]
  @with_two_ops [:with_make_ref, :with_get_ref, :with_get_ref_undef]
  @iterator_start_ops [:for_of_start, :for_await_of_start]

  @doc "Checks stack underflow, joins, catch state, and the declared maximum."
  @spec verify(Function.t()) :: :ok | {:error, term()}
  def verify(%Function{stack_size: declared} = function) do
    with {:ok, analysis} <- analyze(function),
         true <- analysis.maximum == declared do
      :ok
    else
      false -> {:error, {:stack_size_mismatch, declared}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns verified instruction-entry stack and catch levels for compiler analysis."
  @spec analyze(Function.t()) ::
          {:ok,
           %{
             levels: %{non_neg_integer() => {non_neg_integer(), term()}},
             maximum: non_neg_integer()
           }}
          | {:error, term()}
  def analyze(%Function{instructions: instructions} = function)
      when is_tuple(instructions) and tuple_size(instructions) > 0 do
    initial = %{function: function, levels: %{0 => {0, nil}}, queue: [0], maximum: 0}

    with {:ok, state} <- walk(initial) do
      {:ok, %{levels: state.levels, maximum: state.maximum}}
    end
  end

  def analyze(%Function{}), do: {:error, :empty_instruction_stream}

  defp walk(%{queue: []} = state), do: {:ok, state}

  defp walk(%{queue: [index | queue]} = state) do
    {depth, catch_index} = Map.fetch!(state.levels, index)
    {opcode, operands} = elem(state.function.instructions, index)
    {name, _size, pops, pushes, format} = Opcodes.info(opcode)
    pops = pops + variable_pops(format, operands)

    if depth < pops do
      {:error, {:stack_underflow, index, depth, pops}}
    else
      next_depth = depth + pushes - pops
      state = %{state | queue: queue, maximum: max(state.maximum, next_depth)}

      with {:ok, transitions} <-
             transitions(name, operands, index, next_depth, catch_index, state),
           {:ok, state} <- enqueue_all(state, transitions) do
        walk(state)
      end
    end
  end

  defp variable_pops(format, [count | _rest]) when format in [:npop, :npop_u16, :npopx],
    do: count

  defp variable_pops(_format, _operands), do: 0

  defp transitions(name, _operands, _index, _depth, _catch_index, _state)
       when name in @terminal_ops,
       do: {:ok, []}

  defp transitions(name, [target | _rest], _index, depth, catch_index, _state)
       when name in @goto_ops,
       do: {:ok, [{target, depth, catch_index}]}

  defp transitions(name, [target | _rest], index, depth, catch_index, _state)
       when name in @conditional_ops,
       do: {:ok, [{target, depth, catch_index}, {index + 1, depth, catch_index}]}

  defp transitions(:gosub, [target], index, depth, catch_index, _state),
    do: {:ok, [{target, depth + 1, catch_index}, {index + 1, depth, catch_index}]}

  defp transitions(name, [_atom, target | _rest], index, depth, catch_index, _state)
       when name in @with_one_ops,
       do: {:ok, [{target, depth + 1, catch_index}, {index + 1, depth, catch_index}]}

  defp transitions(name, [_atom, target | _rest], index, depth, catch_index, _state)
       when name in @with_two_ops,
       do: {:ok, [{target, depth + 2, catch_index}, {index + 1, depth, catch_index}]}

  defp transitions(:with_put_var, [_atom, target | _rest], index, depth, catch_index, _state)
       when depth > 0,
       do: {:ok, [{target, depth - 1, catch_index}, {index + 1, depth, catch_index}]}

  defp transitions(:with_put_var, _operands, index, depth, _catch_index, _state),
    do: {:error, {:stack_underflow, index, depth, depth + 1}}

  defp transitions(:catch, [target], index, depth, catch_index, _state),
    do: {:ok, [{target, depth, catch_index}, {index + 1, depth, index}]}

  defp transitions(name, _operands, index, depth, _catch_index, _state)
       when name in @iterator_start_ops,
       do: {:ok, [{index + 1, depth, index}]}

  defp transitions(name, _operands, index, depth, catch_index, state)
       when name in [:drop, :nip, :nip1, :iterator_close] do
    catch_level = catch_level(name, depth)
    catch_index = maybe_leave_catch(catch_index, catch_level, state)
    {:ok, [{index + 1, depth, catch_index}]}
  end

  defp transitions(:nip_catch, _operands, index, _depth, nil, _state),
    do: {:error, {:missing_catch, index}}

  defp transitions(:nip_catch, _operands, index, _depth, catch_index, state) do
    {entry_depth, parent_catch} = Map.fetch!(state.levels, catch_index)
    extra = if opcode_name(state, catch_index) == :catch, do: 1, else: 2
    {:ok, [{index + 1, entry_depth + extra, parent_catch}]}
  end

  defp transitions(_name, _operands, index, depth, catch_index, _state),
    do: {:ok, [{index + 1, depth, catch_index}]}

  defp catch_level(:drop, depth), do: depth
  defp catch_level(name, depth) when name in [:nip, :nip1], do: depth - 1
  defp catch_level(:iterator_close, depth), do: depth + 2

  defp maybe_leave_catch(nil, _catch_level, _state), do: nil

  defp maybe_leave_catch(catch_index, catch_level, state) do
    {entry_depth, parent_catch} = Map.fetch!(state.levels, catch_index)

    entry_depth =
      if opcode_name(state, catch_index) == :catch, do: entry_depth, else: entry_depth + 1

    if catch_level == entry_depth, do: parent_catch, else: catch_index
  end

  defp opcode_name(state, index) do
    {opcode, _operands} = elem(state.function.instructions, index)
    {name, _size, _pops, _pushes, _format} = Opcodes.info(opcode)
    name
  end

  defp enqueue_all(state, transitions) do
    Enum.reduce_while(transitions, {:ok, state}, fn transition, {:ok, state} ->
      case enqueue(state, transition) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp enqueue(state, {index, depth, catch_index})
       when index >= 0 and index < tuple_size(state.function.instructions) and depth >= 0 do
    case Map.fetch(state.levels, index) do
      :error ->
        {:ok,
         %{
           state
           | levels: Map.put(state.levels, index, {depth, catch_index}),
             queue: [index | state.queue],
             maximum: max(state.maximum, depth)
         }}

      {:ok, {^depth, ^catch_index}} ->
        {:ok, state}

      {:ok, {existing_depth, existing_catch}} ->
        {:error,
         {:inconsistent_stack, index, {existing_depth, existing_catch}, {depth, catch_index}}}
    end
  end

  defp enqueue(_state, {index, depth, _catch_index}) when depth < 0,
    do: {:error, {:stack_underflow, index, depth, 0}}

  defp enqueue(_state, {index, _depth, _catch_index}), do: {:error, {:invalid_fallthrough, index}}
end
