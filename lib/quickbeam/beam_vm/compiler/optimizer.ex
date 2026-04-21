defmodule QuickBEAM.BeamVM.Compiler.Optimizer do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.Analysis
  alias QuickBEAM.BeamVM.Opcodes

  @push_one_ops [
    Opcodes.num(:push_i32),
    Opcodes.num(:push_i16),
    Opcodes.num(:push_i8),
    Opcodes.num(:push_1)
  ]
  @get_loc_ops [
    Opcodes.num(:get_loc),
    Opcodes.num(:get_loc0),
    Opcodes.num(:get_loc1),
    Opcodes.num(:get_loc2),
    Opcodes.num(:get_loc3),
    Opcodes.num(:get_loc8)
  ]

  def optimize(instructions, constants \\ []) do
    instructions
    |> fold_literals(constants)
    |> peephole_loc_updates()
    |> simplify_constant_branches()
    |> rewrite_forwarding_targets()
  end

  defp fold_literals(instructions, constants) do
    instructions
    |> Enum.with_index()
    |> Enum.reduce(instructions, fn {{_op, _args}, idx}, acc ->
      maybe_fold_at(acc, idx, constants)
    end)
  end

  defp maybe_fold_at(instructions, idx, constants) do
    case Enum.slice(instructions, idx, 3) do
      [a, b, c] ->
        fold_binary_window(instructions, idx, a, b, c, constants)

      _ ->
        case Enum.slice(instructions, idx, 2) do
          [a, b] -> fold_unary_window(instructions, idx, a, b, constants)
          _ -> instructions
        end
    end
  end

  defp fold_binary_window(instructions, idx, a, b, c, constants) do
    with {:ok, left} <- instruction_literal(a, constants),
         {:ok, right} <- instruction_literal(b, constants),
         {:ok, op_name} <- Analysis.opcode_name(elem(c, 0)),
         {:ok, result} <- fold_binary(op_name, left, right),
         {:ok, replacement} <- literal_instruction(result) do
      replace_window(instructions, idx, [replacement, nop(), nop()])
    else
      _ -> instructions
    end
  end

  defp fold_unary_window(instructions, idx, a, b, constants) do
    with {:ok, value} <- instruction_literal(a, constants),
         {:ok, op_name} <- Analysis.opcode_name(elem(b, 0)),
         {:ok, result} <- fold_unary(op_name, value),
         {:ok, replacement} <- literal_instruction(result) do
      replace_window(instructions, idx, [replacement, nop()])
    else
      _ -> instructions
    end
  end

  defp fold_binary(:add, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left + right}

  defp fold_binary(:sub, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left - right}

  defp fold_binary(:mul, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left * right}

  defp fold_binary(:lt, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left < right}

  defp fold_binary(:lte, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left <= right}

  defp fold_binary(:gt, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left > right}

  defp fold_binary(:gte, left, right) when is_integer(left) and is_integer(right),
    do: {:ok, left >= right}

  defp fold_binary(:strict_eq, left, right), do: {:ok, left === right}
  defp fold_binary(:strict_neq, left, right), do: {:ok, left !== right}
  defp fold_binary(_name, _left, _right), do: :error

  defp fold_unary(:neg, value) when is_integer(value), do: {:ok, -value}
  defp fold_unary(:plus, value) when is_integer(value), do: {:ok, value}
  defp fold_unary(:lnot, value) when is_boolean(value), do: {:ok, not value}
  defp fold_unary(_name, _value), do: :error

  defp peephole_loc_updates(instructions) do
    instructions
    |> Enum.with_index()
    |> Enum.reduce(instructions, fn {{_op, _args}, idx}, acc ->
      case Enum.slice(acc, idx, 4) do
        [a, b, c, d] -> rewrite_loc_update_window(acc, idx, a, b, c, d)
        _ -> acc
      end
    end)
  end

  defp rewrite_loc_update_window(instructions, idx, a, b, c, d) do
    with {:ok, get_name} <- Analysis.opcode_name(elem(a, 0)),
         true <- get_name in [:get_loc, :get_loc0, :get_loc1, :get_loc2, :get_loc3, :get_loc8],
         [slot_idx] <- elem(a, 1),
         {:ok, put_name} <- Analysis.opcode_name(elem(d, 0)),
         true <- put_name in [:put_loc, :put_loc0, :put_loc1, :put_loc2, :put_loc3, :put_loc8],
         [^slot_idx] <- elem(d, 1) do
      case {b, Analysis.opcode_name(elem(c, 0))} do
        {{op_b, [1]}, {:ok, :add}} when op_b in @push_one_ops ->
          replace_window(instructions, idx, [nop(), nop(), inc_loc(slot_idx), nop()])

        {{op_b, [1]}, {:ok, :sub}} when op_b in @push_one_ops ->
          replace_window(instructions, idx, [nop(), nop(), dec_loc(slot_idx), nop()])

        {{op_b, [other_slot]}, {:ok, :add}}
        when op_b in @get_loc_ops and is_integer(other_slot) ->
          replace_window(instructions, idx, [nop(), b, add_loc(slot_idx), nop()])

        _ ->
          instructions
      end
    else
      _ -> instructions
    end
  end

  defp simplify_constant_branches(instructions) do
    instructions
    |> Enum.with_index()
    |> Enum.reduce(instructions, fn {{_op, _args}, idx}, acc ->
      case Enum.slice(acc, idx, 2) do
        [cond_insn, branch_insn] -> simplify_branch_window(acc, idx, cond_insn, branch_insn)
        _ -> acc
      end
    end)
  end

  defp simplify_branch_window(instructions, idx, cond_insn, branch_insn) do
    case {instruction_boolean(cond_insn), branch_insn} do
      {{:ok, true}, {op, [target]}} ->
        case Analysis.opcode_name(op) do
          {:ok, :if_true} -> replace_window(instructions, idx, [nop(), goto(target)])
          {:ok, :if_true8} -> replace_window(instructions, idx, [nop(), goto(target)])
          {:ok, :if_false} -> replace_window(instructions, idx, [nop(), nop()])
          {:ok, :if_false8} -> replace_window(instructions, idx, [nop(), nop()])
          _ -> instructions
        end

      {{:ok, false}, {op, [target]}} ->
        case Analysis.opcode_name(op) do
          {:ok, :if_false} -> replace_window(instructions, idx, [nop(), goto(target)])
          {:ok, :if_false8} -> replace_window(instructions, idx, [nop(), goto(target)])
          {:ok, :if_true} -> replace_window(instructions, idx, [nop(), nop()])
          {:ok, :if_true8} -> replace_window(instructions, idx, [nop(), nop()])
          _ -> instructions
        end

      _ ->
        instructions
    end
  end

  defp rewrite_forwarding_targets(instructions) do
    if Enum.any?(instructions, fn {op, _args} ->
         match?({:ok, name} when name in [:catch, :gosub, :ret], Analysis.opcode_name(op))
       end) do
      instructions
    else
      entries = Analysis.block_entries(instructions)
      next_entry = fn start -> Analysis.next_entry(entries, start) || length(instructions) end

      forwarding =
        Enum.reduce(entries, %{}, fn start, acc ->
          case {next_entry.(start), Enum.at(instructions, start)} do
            {next, {op, [target]}} when next == start + 1 ->
              case Analysis.opcode_name(op) do
                {:ok, name} when name in [:goto, :goto8, :goto16] -> Map.put(acc, start, target)
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      if forwarding == %{} do
        instructions
      else
        Enum.map(instructions, fn {op, args} = insn ->
          case {Analysis.opcode_name(op), args} do
            {{:ok, name}, [target]}
            when name in [:goto, :goto8, :goto16, :if_true, :if_true8, :if_false, :if_false8] ->
              {op, [follow_forwarding(target, forwarding)]}

            _ ->
              insn
          end
        end)
      end
    end
  end

  defp follow_forwarding(target, forwarding) do
    case Map.get(forwarding, target) do
      nil -> target
      next when next == target -> target
      next -> follow_forwarding(next, forwarding)
    end
  end

  defp instruction_boolean(insn) do
    case instruction_literal(insn, []) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp instruction_literal({op, args}, constants) do
    case Analysis.opcode_name(op) do
      {:ok, :push_i32} ->
        {:ok, hd(args)}

      {:ok, :push_i16} ->
        {:ok, hd(args)}

      {:ok, :push_i8} ->
        {:ok, hd(args)}

      {:ok, :push_minus1} ->
        {:ok, -1}

      {:ok, name}
      when name in [:push_0, :push_1, :push_2, :push_3, :push_4, :push_5, :push_6, :push_7] ->
        {:ok, String.to_integer(String.replace_prefix(Atom.to_string(name), "push_", ""))}

      {:ok, :push_true} ->
        {:ok, true}

      {:ok, :push_false} ->
        {:ok, false}

      {:ok, :null} ->
        {:ok, nil}

      {:ok, :undefined} ->
        {:ok, :undefined}

      {:ok, :push_empty_string} ->
        {:ok, ""}

      {:ok, name} when name in [:push_const, :push_const8] ->
        literal_const(constants, hd(args))

      _ ->
        :error
    end
  end

  defp literal_const(constants, idx) do
    case Enum.at(constants, idx) do
      value when is_integer(value) -> {:ok, value}
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, nil}
      :undefined -> {:ok, :undefined}
      "" -> {:ok, ""}
      _ -> :error
    end
  end

  defp literal_instruction(value) when is_integer(value),
    do: {:ok, {Opcodes.num(:push_i32), [value]}}

  defp literal_instruction(true), do: {:ok, {Opcodes.num(:push_true), []}}
  defp literal_instruction(false), do: {:ok, {Opcodes.num(:push_false), []}}

  defp replace_window(instructions, idx, replacements) do
    prefix = Enum.take(instructions, idx)
    suffix = Enum.drop(instructions, idx + length(replacements))
    prefix ++ replacements ++ suffix
  end

  defp nop, do: {Opcodes.num(:nop), []}
  defp goto(target), do: {Opcodes.num(:goto16), [target]}
  defp inc_loc(idx), do: {Opcodes.num(:inc_loc), [idx]}
  defp dec_loc(idx), do: {Opcodes.num(:dec_loc), [idx]}
  defp add_loc(idx), do: {Opcodes.num(:add_loc), [idx]}
end
