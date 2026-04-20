defmodule QuickBEAM.BeamVM.Compiler.Analysis do
  @moduledoc false

  alias QuickBEAM.BeamVM.Opcodes

  def block_entries(instructions) do
    entries =
      instructions
      |> Enum.with_index()
      |> Enum.reduce(MapSet.new([0]), fn {{op, args}, idx}, acc ->
        case opcode_name(op) do
          {:ok, name} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
            [target] = args
            acc |> MapSet.put(target) |> MapSet.put(idx + 1)

          {:ok, name} when name in [:goto, :goto8, :goto16] ->
            [target] = args
            MapSet.put(acc, target)

          _ ->
            acc
        end
      end)

    entries
    |> MapSet.to_list()
    |> Enum.sort()
  end

  def next_entry(entries, start), do: Enum.find(entries, &(&1 > start))

  def infer_block_stack_depths(instructions, entries) do
    walk_block_stack_depths(instructions, entries, [{0, 0}], %{})
  end

  def opcode_name(op) do
    case Opcodes.info(op) do
      {name, _size, _pop, _push, _fmt} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, op}}
    end
  end

  defp walk_block_stack_depths(_instructions, _entries, [], depths), do: {:ok, depths}

  defp walk_block_stack_depths(instructions, entries, [{start, depth} | rest], depths) do
    case Map.fetch(depths, start) do
      {:ok, ^depth} ->
        walk_block_stack_depths(instructions, entries, rest, depths)

      {:ok, other_depth} ->
        {:error, {:inconsistent_block_stack_depth, start, other_depth, depth}}

      :error ->
        with {:ok, successors} <- simulate_block_stack_depths(instructions, entries, start, depth) do
          walk_block_stack_depths(
            instructions,
            entries,
            rest ++ successors,
            Map.put(depths, start, depth)
          )
        end
    end
  end

  defp simulate_block_stack_depths(instructions, entries, start, depth) do
    next_entry = next_entry(entries, start)
    do_simulate_block_stack_depths(instructions, start, next_entry, depth)
  end

  defp do_simulate_block_stack_depths(instructions, idx, _next_entry, _depth)
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx}}
  end

  defp do_simulate_block_stack_depths(_instructions, idx, idx, depth), do: {:ok, [{idx, depth}]}

  defp do_simulate_block_stack_depths(instructions, idx, next_entry, depth) do
    {op, args} = Enum.at(instructions, idx)

    with {:ok, next_depth} <- apply_stack_effect(op, args, depth) do
      case {opcode_name(op), args} do
        {{:ok, name}, [target]} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
          if is_nil(next_entry) do
            {:error, {:missing_fallthrough_block, target, name}}
          else
            {:ok, [{target, next_depth}, {next_entry, next_depth}]}
          end

        {{:ok, name}, [target]} when name in [:goto, :goto8, :goto16] ->
          {:ok, [{target, next_depth}]}

        {{:ok, name}, [_argc]} when name in [:tail_call, :tail_call_method] ->
          {:ok, []}

        {{:ok, :return}, []} ->
          {:ok, []}

        {{:ok, :return_undef}, []} ->
          {:ok, []}

        _ ->
          do_simulate_block_stack_depths(instructions, idx + 1, next_entry, next_depth)
      end
    end
  end

  defp apply_stack_effect(op, args, depth) do
    with {:ok, pop_count, push_count} <- stack_effect(op, args),
         true <- depth >= pop_count or {:error, {:stack_underflow_at, op, args, depth, pop_count}} do
      {:ok, depth - pop_count + push_count}
    end
  end

  defp stack_effect(op, args) do
    case {opcode_name(op), args} do
      {{:ok, name}, [argc]} when name in [:call, :call0, :call1, :call2, :call3, :tail_call] ->
        {:ok, argc + 1, if(name == :tail_call, do: 0, else: 1)}

      {{:ok, name}, [argc]} when name in [:call_method, :tail_call_method] ->
        {:ok, argc + 2, if(name == :tail_call_method, do: 0, else: 1)}

      {{:ok, :array_from}, [argc]} ->
        {:ok, argc, 1}

      {{:ok, _name}, _} ->
        case Opcodes.info(op) do
          {_name, _size, pop_count, push_count, _fmt} -> {:ok, pop_count, push_count}
          nil -> {:error, {:unknown_opcode, op}}
        end

      {{:error, _} = error, _} ->
        error
    end
  end
end
