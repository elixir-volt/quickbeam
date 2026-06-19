defmodule QuickBEAM.VM.Compiler.Lowering.ObjectLiteralFastPath do
  @moduledoc "Fast-path lowering for object literals with statically known data fields."

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Emit, Literals, State}
  alias QuickBEAM.VM.OpcodeSpec

  @doc "Attempts to lower an object literal followed by define_field opcodes."
  def try_lower(instructions, block_limit, idx, arg_count, state) do
    block_limit = min(block_limit, tuple_size(instructions))

    with {:ok, map_pairs, skip_to, state} <-
           collect_define_fields(instructions, block_limit, idx + 1, arg_count, state) do
      keys_list = Enum.map(map_pairs, &elem(&1, 0))
      vals_list = Enum.map(map_pairs, &elem(&1, 1))
      keys_tuple = Builder.tuple_expr(keys_list)
      vals_tuple = Builder.tuple_expr(vals_list)

      {obj, state} =
        Emit.bind(
          state,
          Builder.temp_name(state.temp),
          State.abi_call(state, :wrap_keyed_object_literal, [keys_tuple, vals_tuple])
        )

      {:ok, Emit.push(state, obj, :object), skip_to}
    end
  end

  defp collect_define_fields(instructions, size, idx, arg_count, state) do
    collect_define_fields(instructions, size, idx, arg_count, state, [], MapSet.new())
  end

  defp collect_define_fields(_instructions, size, idx, _arg_count, state, acc, _seen_keys)
       when idx + 1 >= size do
    if acc == [], do: :not_literal, else: {:ok, Enum.reverse(acc), idx, state}
  end

  defp collect_define_fields(instructions, size, idx, arg_count, state, acc, seen_keys) do
    val_instr = elem(instructions, idx)
    df_instr = elem(instructions, idx + 1)

    with {val_op, val_args} <- val_instr,
         {df_op, [key_idx]} <- df_instr,
         {:ok, :define_field} <- CFG.opcode_name(df_op),
         {:ok, val_expr, safe_value?, new_state} <-
           lower_value_opcode(val_op, val_args, arg_count, state) do
      key_name = Builder.atom_name(new_state, key_idx)

      cond do
        key_name == "__proto__" ->
          :not_literal

        is_binary(key_name) ->
          key_expr = Builder.literal(key_name)
          pair = {key_expr, val_expr, safe_value?}
          acc = upsert_pair(acc, key_name, pair, MapSet.member?(seen_keys, key_name))

          collect_define_fields(
            instructions,
            size,
            idx + 2,
            arg_count,
            new_state,
            acc,
            MapSet.put(seen_keys, key_name)
          )

        acc == [] ->
          :not_literal

        true ->
          {:ok, Enum.reverse(acc), idx, state}
      end
    else
      _ ->
        if acc == [], do: :not_literal, else: {:ok, Enum.reverse(acc), idx, state}
    end
  end

  defp upsert_pair(acc, _key_name, pair, false), do: [pair | acc]

  defp upsert_pair(acc, key_name, pair, true) do
    Enum.map(acc, fn {key_expr, _value_expr, _safe_value?} = existing ->
      if Literals.string_lossy(key_expr) == key_name, do: pair, else: existing
    end)
  end

  defp lower_value_opcode(op, args, _arg_count, state) do
    case CFG.opcode_name(op) do
      {:ok, name} when name in [:push_i32, :push_i16, :push_i8] ->
        {:ok, Builder.integer(hd(args)), true, state}

      {:ok, :null} ->
        {:ok, Builder.atom(nil), true, state}

      {:ok, :undefined} ->
        {:ok, Builder.atom(:undefined), true, state}

      {:ok, :push_false} ->
        {:ok, Builder.atom(false), true, state}

      {:ok, :push_true} ->
        {:ok, Builder.atom(true), true, state}

      {:ok, :push_empty_string} ->
        {:ok, Builder.literal(""), true, state}

      {:ok, :push_atom_value} ->
        {:ok, State.constant_call(state, :push_atom_value, [Builder.literal(hd(args))]), false,
         state}

      {:ok, name} ->
        if OpcodeSpec.small_int_push?(name) do
          {:ok, value} = OpcodeSpec.small_int_push(name)
          {:ok, Builder.integer(value), true, state}
        else
          :not_literal
        end

      _ ->
        :error
    end
  end
end
