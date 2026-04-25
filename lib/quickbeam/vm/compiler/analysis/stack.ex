defmodule QuickBEAM.VM.Compiler.Analysis.Stack do
  @moduledoc "Stack-depth inference: computes operand-stack depth at every basic-block entry."

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Opcodes

  def infer_block_stack_depths(instructions, entries) do
    t = List.to_tuple(instructions)
    walk_block_stack_depths(t, tuple_size(t), entries, [{0, 0}], %{})
  end

  def stack_effect(op, args) do
    case {CFG.opcode_name(op), args} do
      {{:ok, name}, [argc]} when name in [:call, :call0, :call1, :call2, :call3, :tail_call] ->
        {:ok, argc + 1, if(name == :tail_call, do: 0, else: 1)}

      {{:ok, name}, [argc]} when name in [:call_method, :tail_call_method] ->
        {:ok, argc + 2, if(name == :tail_call_method, do: 0, else: 1)}

      {{:ok, :call_constructor}, [argc]} ->
        {:ok, argc + 2, 1}

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

  defp walk_block_stack_depths(_instructions, _size, _entries, [], depths), do: {:ok, depths}

  defp walk_block_stack_depths(instructions, size, entries, [{start, depth} | rest], depths) do
    case Map.fetch(depths, start) do
      {:ok, ^depth} ->
        walk_block_stack_depths(instructions, size, entries, rest, depths)

      {:ok, other_depth} ->
        {:error, {:inconsistent_block_stack_depth, start, other_depth, depth}}

      :error ->
        with {:ok, successors} <- simulate_block_stack_depths(instructions, size, entries, start, depth) do
          walk_block_stack_depths(
            instructions,
            size,
            entries,
            rest ++ successors,
            Map.put(depths, start, depth)
          )
        end
    end
  end

  defp simulate_block_stack_depths(instructions, size, entries, start, depth) do
    next_entry = CFG.next_entry(entries, start)
    do_simulate_block_stack_depths(instructions, size, start, next_entry, depth)
  end

  defp do_simulate_block_stack_depths(_instructions, size, idx, _next_entry, _depth)
       when idx >= size do
    {:error, {:missing_terminator, idx}}
  end

  defp do_simulate_block_stack_depths(_instructions, _size, idx, idx, depth), do: {:ok, [{idx, depth}]}

  defp do_simulate_block_stack_depths(instructions, size, idx, next_entry, depth) do
    {op, args} = elem(instructions, idx)

    with {:ok, next_depth} <- apply_stack_effect(op, args, depth) do
      case {CFG.opcode_name(op), args} do
        {{:ok, name}, [target]} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
          if is_nil(next_entry) do
            {:error, {:missing_fallthrough_block, target, name}}
          else
            {:ok, [{target, next_depth}, {next_entry, next_depth}]}
          end

        {{:ok, :catch}, [target]} ->
          with {:ok, successors} <-
                 do_simulate_block_stack_depths(instructions, size, idx + 1, next_entry, next_depth) do
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

        {{:ok, :return_async}, []} ->
          {:ok, []}

        {{:ok, :initial_yield}, []} ->
          {:ok, []}

        {{:ok, :yield}, []} ->
          {:ok, []}

        {{:ok, :yield_star}, []} ->
          {:ok, []}

        {{:ok, :async_yield_star}, []} ->
          {:ok, []}

        {{:ok, :gosub}, [_target]} ->
          {:ok, []}

        {{:ok, :ret}, []} ->
          {:ok, []}

        _ ->
          do_simulate_block_stack_depths(instructions, size, idx + 1, next_entry, next_depth)
      end
    end
  end

  defp apply_stack_effect(op, args, depth) do
    with {:ok, pop_count, push_count} <- stack_effect(op, args),
         true <- depth >= pop_count or {:error, {:stack_underflow_at, op, args, depth, pop_count}} do
      {:ok, depth - pop_count + push_count}
    end
  end
end
