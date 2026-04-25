defmodule QuickBEAM.VM.Interpreter.Ops.Arithmetic do
  @moduledoc "Arithmetic, bitwise, comparison, and unary opcodes."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.{Closures, Frame, Values}

      # ── Arithmetic ──

      defp run({@op_add, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.add(a, b) end, true)

      defp run({@op_sub, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.sub(a, b) end, true)

      defp run({@op_mul, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.mul(a, b) end, true)

      defp run({@op_div, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.js_div(a, b) end, true)

      defp run({@op_mod, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.mod(a, b) end, true)

      defp run({@op_pow, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.pow(a, b) end, true)

      # ── Bitwise ──

      defp run({@op_band, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.band(a, b) end, true)

      defp run({@op_bor, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.bor(a, b) end, true)

      defp run({@op_bxor, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.bxor(a, b) end, true)

      defp run({@op_shl, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.shl(a, b) end, true)

      defp run({@op_sar, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.sar(a, b) end, true)

      defp run({@op_shr, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.shr(a, b) end, true)

      # ── Comparison ──

      defp run({@op_lt, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.lt(a, b) end, true)

      defp run({@op_lte, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.lte(a, b) end, true)

      defp run({@op_gt, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.gt(a, b) end, true)

      defp run({@op_gte, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.gte(a, b) end, true)

      defp run({@op_eq, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.eq(a, b) end, true)

      defp run({@op_neq, []}, pc, frame, [b, a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.neq(a, b) end, true)

      defp run({@op_strict_eq, []}, pc, frame, [b, a | rest], gas, ctx),
        do: run(pc + 1, frame, [Values.strict_eq(a, b) | rest], gas, ctx)

      defp run({@op_strict_neq, []}, pc, frame, [b, a | rest], gas, ctx),
        do: run(pc + 1, frame, [not Values.strict_eq(a, b) | rest], gas, ctx)

      # ── Unary ──

      defp run({@op_neg, []}, pc, frame, [a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.neg(a) end, true)

      defp run({@op_plus, []}, pc, frame, [a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.to_number(a) end, true)

      defp run({@op_inc, []}, pc, frame, [{:bigint, n} | rest], gas, ctx),
        do: run(pc + 1, frame, [{:bigint, n + 1} | rest], gas, ctx)

      defp run({@op_inc, []}, pc, frame, [a | rest], gas, ctx) when is_number(a),
        do: run(pc + 1, frame, [a + 1 | rest], gas, ctx)

      defp run({@op_inc, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [Values.add(Values.to_number(a), 1) | rest], gas, ctx)

      defp run({@op_dec, []}, pc, frame, [{:bigint, n} | rest], gas, ctx),
        do: run(pc + 1, frame, [{:bigint, n - 1} | rest], gas, ctx)

      defp run({@op_dec, []}, pc, frame, [a | rest], gas, ctx) when is_number(a),
        do: run(pc + 1, frame, [a - 1 | rest], gas, ctx)

      defp run({@op_dec, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [Values.sub(Values.to_number(a), 1) | rest], gas, ctx)

      defp run({@op_post_inc, []}, pc, frame, [{:bigint, n} = val | rest], gas, ctx),
        do: run(pc + 1, frame, [{:bigint, n + 1}, val | rest], gas, ctx)

      defp run({@op_post_inc, []}, pc, frame, [a | rest], gas, ctx) do
        num = Values.to_number(a)
        run(pc + 1, frame, [Values.add(num, 1), num | rest], gas, ctx)
      end

      defp run({@op_post_dec, []}, pc, frame, [{:bigint, n} = val | rest], gas, ctx),
        do: run(pc + 1, frame, [{:bigint, n - 1}, val | rest], gas, ctx)

      defp run({@op_post_dec, []}, pc, frame, [a | rest], gas, ctx) do
        num = Values.to_number(a)
        run(pc + 1, frame, [Values.sub(num, 1), num | rest], gas, ctx)
      end

      defp run({@op_inc_loc, [idx]}, pc, frame, stack, gas, ctx) do
        locals = elem(frame, Frame.locals())
        vrefs = elem(frame, Frame.var_refs())
        l2v = elem(frame, Frame.l2v())
        old = elem(locals, idx)

        new_val =
          case old do
            {:bigint, n} -> {:bigint, n + 1}
            n when is_number(n) -> n + 1
            _ -> Values.add(Values.to_number(old), 1)
          end

        Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
        run(pc + 1, put_local(frame, idx, new_val), stack, gas, ctx)
      end

      defp run({@op_dec_loc, [idx]}, pc, frame, stack, gas, ctx) do
        locals = elem(frame, Frame.locals())
        vrefs = elem(frame, Frame.var_refs())
        l2v = elem(frame, Frame.l2v())
        old = elem(locals, idx)

        new_val =
          case old do
            {:bigint, n} -> {:bigint, n - 1}
            n when is_number(n) -> n - 1
            _ -> Values.sub(Values.to_number(old), 1)
          end

        Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
        run(pc + 1, put_local(frame, idx, new_val), stack, gas, ctx)
      end

      defp run({@op_add_loc, [idx]}, pc, frame, [val | rest], gas, ctx) do
        locals = elem(frame, Frame.locals())
        vrefs = elem(frame, Frame.var_refs())
        l2v = elem(frame, Frame.l2v())
        new_val = Values.add(elem(locals, idx), val)
        Closures.write_captured_local(l2v, idx, new_val, locals, vrefs)
        run(pc + 1, put_local(frame, idx, new_val), rest, gas, ctx)
      end

      defp run({@op_not, []}, pc, frame, [a | rest], gas, ctx),
        do: catch_and_dispatch(pc, frame, rest, gas, ctx, fn -> Values.bnot(a) end, true)

      defp run({@op_lnot, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [not Values.truthy?(a) | rest], gas, ctx)

      defp run({@op_typeof, []}, pc, frame, [a | rest], gas, ctx),
        do: run(pc + 1, frame, [Values.typeof(a) | rest], gas, ctx)
    end
  end
end
