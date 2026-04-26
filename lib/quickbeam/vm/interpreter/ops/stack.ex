defmodule QuickBEAM.VM.Interpreter.Ops.Stack do
  @moduledoc "Stack manipulation and constant-push opcodes."

  @doc "Installs the Stack manipulation and constant-push opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Frame
      alias QuickBEAM.VM.Names
      # ── Push constants ──

      defp run({op, [val]}, pc, frame, stack, gas, ctx)
           when op in [
                  @op_push_i32,
                  @op_push_i8,
                  @op_push_i16,
                  @op_push_minus1,
                  @op_push_0,
                  @op_push_1,
                  @op_push_2,
                  @op_push_3,
                  @op_push_4,
                  @op_push_5,
                  @op_push_6,
                  @op_push_7
                ],
           do: run(pc + 1, frame, [val | stack], gas, ctx)

      defp run({op, [idx]}, pc, frame, stack, gas, ctx)
           when op in [@op_push_const, @op_push_const8] do
        val = Names.resolve_const(elem(frame, Frame.constants()), idx)
        val = materialize_constant(val)
        run(pc + 1, frame, [val | stack], gas, ctx)
      end

      defp run({@op_push_atom_value, [atom_idx]}, pc, frame, stack, gas, ctx) do
        run(pc + 1, frame, [Names.resolve_atom(ctx, atom_idx) | stack], gas, ctx)
      end

      defp run({@op_undefined, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, [:undefined | stack], gas, ctx)

      defp run({@op_null, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, [nil | stack], gas, ctx)

      defp run({@op_push_false, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, [false | stack], gas, ctx)

      defp run({@op_push_true, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, [true | stack], gas, ctx)

      defp run({@op_push_empty_string, []}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, ["" | stack], gas, ctx)

      defp run({@op_push_bigint_i32, [val]}, pc, frame, stack, gas, ctx),
        do: run(pc + 1, frame, [{:bigint, val} | stack], gas, ctx)

      # ── Stack manipulation ──

      defp run({@op_drop, []}, pc, frame, [_ | rest], gas, ctx),
        do: run(pc + 1, frame, rest, gas, ctx)

      defp run({@op_nip, []}, pc, frame, [a, _b | rest], gas, ctx),
        do: run(pc + 1, frame, [a | rest], gas, ctx)

      defp run({@op_nip1, []}, pc, frame, [a, b, _c | rest], gas, ctx),
        do: run(pc + 1, frame, [a, b | rest], gas, ctx)

      defp run({@op_dup, []}, pc, frame, [a | _] = stack, gas, ctx),
        do: run(pc + 1, frame, [a | stack], gas, ctx)

      defp run({@op_dup1, []}, pc, frame, [a, b | _] = stack, gas, ctx) do
        run(pc + 1, frame, [a, b | stack], gas, ctx)
      end

      defp run({@op_dup2, []}, pc, frame, [a, b | _rest] = stack, gas, ctx) do
        run(pc + 1, frame, [a, b | stack], gas, ctx)
      end

      defp run({@op_dup3, []}, pc, frame, [a, b, c | _rest] = stack, gas, ctx) do
        run(pc + 1, frame, [a, b, c | stack], gas, ctx)
      end

      defp run({@op_insert2, []}, pc, frame, [a, b | rest], gas, ctx),
        do: run(pc + 1, frame, [a, b, a | rest], gas, ctx)

      defp run({@op_insert3, []}, pc, frame, [a, b, c | rest], gas, ctx),
        do: run(pc + 1, frame, [a, b, c, a | rest], gas, ctx)

      defp run({@op_insert4, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
        do: run(pc + 1, frame, [a, b, c, d, a | rest], gas, ctx)

      defp run({@op_perm3, []}, pc, frame, [a, b, c | rest], gas, ctx),
        do: run(pc + 1, frame, [a, c, b | rest], gas, ctx)

      defp run({@op_perm4, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
        do: run(pc + 1, frame, [a, c, d, b | rest], gas, ctx)

      defp run({@op_perm5, []}, pc, frame, [a, b, c, d, e | rest], gas, ctx),
        do: run(pc + 1, frame, [a, c, d, e, b | rest], gas, ctx)

      defp run({@op_swap, []}, pc, frame, [a, b | rest], gas, ctx),
        do: run(pc + 1, frame, [b, a | rest], gas, ctx)

      defp run({@op_swap2, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
        do: run(pc + 1, frame, [c, d, a, b | rest], gas, ctx)

      defp run({@op_rot3l, []}, pc, frame, [a, b, c | rest], gas, ctx),
        do: run(pc + 1, frame, [c, a, b | rest], gas, ctx)

      defp run({@op_rot3r, []}, pc, frame, [a, b, c | rest], gas, ctx),
        do: run(pc + 1, frame, [b, c, a | rest], gas, ctx)

      defp run({@op_rot4l, []}, pc, frame, [a, b, c, d | rest], gas, ctx),
        do: run(pc + 1, frame, [d, a, b, c | rest], gas, ctx)

      defp run({@op_rot5l, []}, pc, frame, [a, b, c, d, e | rest], gas, ctx),
        do: run(pc + 1, frame, [e, a, b, c, d | rest], gas, ctx)
    end
  end
end
