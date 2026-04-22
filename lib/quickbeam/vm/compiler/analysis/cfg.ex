defmodule QuickBEAM.VM.Compiler.Analysis.CFG do
  @moduledoc false

  alias QuickBEAM.VM.Opcodes

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

          {:ok, name}
          when name in [
                 :initial_yield,
                 :yield,
                 :yield_star,
                 :async_yield_star,
                 :gosub
               ] ->
            MapSet.put(acc, idx + 1)

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
    predecessor_sources(instructions, entries)
    |> Enum.into(%{}, fn {target, preds} -> {target, length(preds)} end)
  end

  def predecessor_sources(instructions, entries) do
    Enum.reduce(entries, %{}, fn start, preds ->
      next = next_entry(entries, start)

      case block_terminal(instructions, start, next) do
        {:branch, target, term_idx} when is_integer(next) ->
          preds
          |> add_predecessor(target, term_idx)
          |> add_predecessor(next, term_idx)

        {:catch, target, term_idx} when is_integer(next) ->
          preds
          |> add_predecessor(target, term_idx)
          |> add_predecessor(next, term_idx)

        {:goto, target, term_idx} ->
          add_predecessor(preds, target, term_idx)

        {:fallthrough, target_idx} ->
          add_predecessor(preds, target_idx, target_idx - 1)

        _ ->
          preds
      end
    end)
  end

  def inlineable_entries(instructions, entries) do
    instructions
    |> predecessor_sources(entries)
    |> Enum.reduce(MapSet.new(), fn {target, preds}, acc ->
      case preds do
        [pred_end] ->
          if pred_end < target and not protected_target?(instructions, target) do
            MapSet.put(acc, target)
          else
            acc
          end

        _ ->
          acc
      end
    end)
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

  defp add_predecessor(preds, target, pred_end),
    do: Map.update(preds, target, [pred_end], &[pred_end | &1])

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
