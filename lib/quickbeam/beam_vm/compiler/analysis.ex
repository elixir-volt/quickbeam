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

          {:ok, name} when name in [:goto, :goto8, :goto16, :catch] ->
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

  def predecessor_counts(instructions, entries) do
    entries
    |> Enum.reduce(%{}, fn start, counts ->
      successors = block_successors(instructions, entries, start)

      Enum.reduce(successors, counts, fn succ, counts ->
        Map.update(counts, succ, 1, &(&1 + 1))
      end)
    end)
  end

  def inlineable_goto_targets(instructions, entries) do
    counts = predecessor_counts(instructions, entries)

    entries
    |> Enum.reduce(MapSet.new(), fn start, acc ->
      next = next_entry(entries, start)

      case block_terminal(instructions, start, next) do
        {:goto, target, term_idx} ->
          if target > term_idx and Map.get(counts, target, 0) == 1 and
               not protected_target?(instructions, target) do
            MapSet.put(acc, target)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  def infer_block_stack_depths(instructions, entries) do
    walk_block_stack_depths(instructions, entries, [{0, 0}], %{})
  end

  def opcode_name(op) do
    case Opcodes.info(op) do
      {name, _size, _pop, _push, _fmt} -> {:ok, name}
      nil -> {:error, {:unknown_opcode, op}}
    end
  end

  def matching_nip_catch(instructions, catch_idx),
    do: find_nip_catch(instructions, catch_idx + 1, 0)

  def block_terminal(instructions, start, next_entry),
    do: do_block_terminal(instructions, start, next_entry)

  def block_successors(instructions, entries, start) do
    next = next_entry(entries, start)

    case block_terminal(instructions, start, next) do
      {:branch, target, _idx} when is_integer(next) -> [target, next]
      {:catch, target, _idx} when is_integer(next) -> [target, next]
      {:goto, target, _idx} -> [target]
      {:fallthrough, target_idx} -> [target_idx]
      _ -> []
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

        {{:ok, :catch}, [target]} ->
          with {:ok, successors} <-
                 do_simulate_block_stack_depths(instructions, idx + 1, next_entry, next_depth) do
            {:ok, [{target, next_depth} | successors]}
          end

        {{:ok, name}, [target]} when name in [:goto, :goto8, :goto16] ->
          {:ok, [{target, next_depth}]}

        {{:ok, name}, [_argc]} when name in [:tail_call, :tail_call_method] ->
          {:ok, []}

        {{:ok, :return}, []} ->
          {:ok, []}

        {{:ok, :return_undef}, []} ->
          {:ok, []}

        {{:ok, :throw}, []} ->
          {:ok, []}

        {{:ok, :throw_error}, _} ->
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

  defp do_block_terminal(instructions, idx, _next_entry) when idx >= length(instructions),
    do: {:done, idx}

  defp do_block_terminal(_instructions, idx, idx), do: {:fallthrough, idx}

  defp do_block_terminal(instructions, idx, next_entry) do
    {op, args} = Enum.at(instructions, idx)

    case {opcode_name(op), args} do
      {{:ok, name}, [target]} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
        {:branch, target, idx}

      {{:ok, :catch}, [target]} ->
        {:catch, target, idx}

      {{:ok, name}, [target]} when name in [:goto, :goto8, :goto16] ->
        {:goto, target, idx}

      {{:ok, name}, [_argc]} when name in [:tail_call, :tail_call_method] ->
        {:done, idx}

      {{:ok, name}, _args} when name in [:return, :return_undef, :throw, :throw_error] ->
        {:done, idx}

      _ ->
        do_block_terminal(instructions, idx + 1, next_entry)
    end
  end

  defp protected_target?(instructions, target) do
    Enum.any?(instructions, fn {op, args} ->
      case {opcode_name(op), args} do
        {{:ok, name}, [^target]} when name in [:catch, :gosub] -> true
        _ -> false
      end
    end)
  end

  defp find_nip_catch(instructions, idx, _depth) when idx >= length(instructions), do: :error

  defp find_nip_catch(instructions, idx, depth) do
    {op, _args} = Enum.at(instructions, idx)

    case opcode_name(op) do
      {:ok, :catch} ->
        find_nip_catch(instructions, idx + 1, depth + 1)

      {:ok, :nip_catch} when depth == 0 ->
        {:ok, idx}

      {:ok, :nip_catch} ->
        find_nip_catch(instructions, idx + 1, depth - 1)

      _ ->
        find_nip_catch(instructions, idx + 1, depth)
    end
  end
end
