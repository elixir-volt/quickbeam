defmodule QuickBEAM.VM.Compiler.Analysis.ControlFlow do
  @moduledoc """
  Builds bounded basic blocks from verified QuickJS instruction tuples.

  The analysis adapts the prototype's graph algorithm but consumes only current
  v26 canonical instruction indexes and does not carry prototype runtime state.
  """

  alias QuickBEAM.VM.Compiler.Analysis.Block
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Bytecode.Opcode

  @conditional_branches [:if_false, :if_false8, :if_true, :if_true8]
  @unconditional_branches [:goto, :goto8, :goto16]
  @exception_branches [:catch, :gosub]
  @with_branches [
    :with_get_var,
    :with_put_var,
    :with_delete_var,
    :with_make_ref,
    :with_get_ref,
    :with_get_ref_undef
  ]
  @terminators [
    :return,
    :return_undef,
    :return_async,
    :throw,
    :throw_error,
    :tail_call,
    :tail_call_method,
    :ret
  ]
  @suspensions [:await, :initial_yield, :yield, :yield_star, :async_yield_star]
  @target_branches @conditional_branches ++ @unconditional_branches ++ @exception_branches
  @block_terminators @target_branches ++ @with_branches ++ @terminators ++ @suspensions

  @doc "Returns ordered basic blocks for one verified function."
  @spec analyze(Function.t()) :: {:ok, [Block.t()]} | {:error, term()}
  def analyze(%Function{instructions: instructions} = function) when is_tuple(instructions) do
    with {:ok, canonical} <- canonical_instructions(function),
         {:ok, entries} <- block_entries(canonical),
         {:ok, blocks} <- build_blocks(canonical, entries) do
      {:ok, attach_predecessors(blocks)}
    end
  end

  def analyze(%Function{}), do: {:error, :missing_instructions}
  def analyze(value), do: {:error, {:invalid_compiler_function, value}}

  @doc "Converts numeric and compact opcodes into canonical names and operands."
  @spec canonical_instructions(Function.t()) ::
          {:ok, [Block.instruction()]} | {:error, term()}
  def canonical_instructions(%Function{instructions: instructions} = function)
      when is_tuple(instructions) do
    instructions
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{opcode, operands}, pc}, {:ok, acc} ->
      case Opcode.info(opcode) do
        {name, _size, _pops, _pushes, _format} when is_list(operands) ->
          {name, operands} = Opcode.expand_short_form(name, operands, function.arg_count)
          {:cont, {:ok, [{pc, name, operands} | acc]}}

        _invalid ->
          {:halt, {:error, {:invalid_compiler_instruction, pc, opcode, operands}}}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, Enum.reverse(canonical)}
      {:error, _reason} = error -> error
    end
  end

  def canonical_instructions(%Function{}), do: {:error, :missing_instructions}

  defp block_entries([]), do: {:error, :empty_instruction_stream}

  defp block_entries(instructions) do
    size = length(instructions)

    entries =
      Enum.reduce(instructions, MapSet.new([0]), fn {pc, name, operands}, entries ->
        entries
        |> add_targets(name, operands)
        |> add_post_terminal(pc, name, size)
      end)

    invalid = Enum.find(entries, &(not is_integer(&1) or &1 < 0 or &1 >= size))

    if invalid == nil,
      do: {:ok, entries |> MapSet.to_list() |> Enum.sort()},
      else: {:error, {:invalid_compiler_target, invalid}}
  end

  defp add_targets(entries, name, [target]) when name in @target_branches,
    do: MapSet.put(entries, target)

  defp add_targets(entries, name, [_atom, target | _rest]) when name in @with_branches,
    do: MapSet.put(entries, target)

  defp add_targets(entries, _name, _operands), do: entries

  defp add_post_terminal(entries, pc, name, size) when name in @block_terminators do
    if pc + 1 < size, do: MapSet.put(entries, pc + 1), else: entries
  end

  defp add_post_terminal(entries, _pc, _name, _size), do: entries

  defp build_blocks(instructions, entries) do
    tuple = List.to_tuple(instructions)
    size = tuple_size(tuple)

    blocks =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {start_pc, index} ->
        next_entry = Enum.at(entries, index + 1, size)
        block_instructions = for pc <- start_pc..(next_entry - 1), do: elem(tuple, pc)
        end_pc = next_entry - 1

        %Block{
          start_pc: start_pc,
          end_pc: end_pc,
          instructions: block_instructions,
          successors: successors(List.last(block_instructions), next_entry, size),
          predecessors: []
        }
      end)

    {:ok, blocks}
  end

  defp successors({_pc, name, [target]}, next_entry, size) when name in @conditional_branches,
    do: valid_successors([target, next_entry], size)

  defp successors({_pc, name, [target]}, _next_entry, size)
       when name in @unconditional_branches,
       do: valid_successors([target], size)

  defp successors({_pc, name, [target]}, next_entry, size) when name in @exception_branches,
    do: valid_successors([target, next_entry], size)

  defp successors({_pc, name, [_atom, target | _rest]}, next_entry, size)
       when name in @with_branches,
       do: valid_successors([target, next_entry], size)

  defp successors({_pc, name, _operands}, _next_entry, _size) when name in @terminators,
    do: []

  defp successors({_pc, name, _operands}, next_entry, size) when name in @suspensions,
    do: valid_successors([next_entry], size)

  defp successors(_instruction, next_entry, size), do: valid_successors([next_entry], size)

  defp valid_successors(successors, size),
    do: successors |> Enum.filter(&(&1 >= 0 and &1 < size)) |> Enum.uniq()

  defp attach_predecessors(blocks) do
    predecessors =
      Enum.reduce(blocks, %{}, fn block, predecessors ->
        Enum.reduce(block.successors, predecessors, fn successor, predecessors ->
          Map.update(predecessors, successor, [block.start_pc], &[block.start_pc | &1])
        end)
      end)

    Enum.map(blocks, fn block ->
      predecessors = predecessors |> Map.get(block.start_pc, []) |> Enum.sort()
      %{block | predecessors: predecessors}
    end)
  end
end
