defmodule QuickBEAM.VM.Interpreter.Ops.Locals do
  @moduledoc "Args, locals, and closure variable reference opcodes."

  @doc "Installs the Args, locals, and closure variable reference opcodes helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.{Heap, Names}
      alias QuickBEAM.VM.Interpreter.{Closures, Frame}

      # ── Args ──

      defp run({op, [idx]}, pc, frame, stack, gas, ctx)
           when op in [@op_get_arg, @op_get_arg0, @op_get_arg1, @op_get_arg2, @op_get_arg3],
           do: run(pc + 1, frame, [get_arg_value(ctx, idx) | stack], gas, ctx)

      # ── Locals ──

      defp run({op, [idx]}, pc, frame, stack, gas, ctx)
           when op in [
                  @op_get_loc,
                  @op_get_loc0,
                  @op_get_loc1,
                  @op_get_loc2,
                  @op_get_loc3,
                  @op_get_loc8
                ] do
        run(
          pc + 1,
          frame,
          [
            Closures.read_captured_local(
              elem(frame, Frame.l2v()),
              idx,
              elem(frame, Frame.locals()),
              elem(frame, Frame.var_refs())
            )
            | stack
          ],
          gas,
          ctx
        )
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
           when op in [
                  @op_put_loc,
                  @op_put_loc0,
                  @op_put_loc1,
                  @op_put_loc2,
                  @op_put_loc3,
                  @op_put_loc8
                ] do
        Closures.write_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          val,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )

        run(pc + 1, put_local(frame, idx, val), rest, gas, ctx)
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
           when op in [
                  @op_set_loc,
                  @op_set_loc0,
                  @op_set_loc1,
                  @op_set_loc2,
                  @op_set_loc3,
                  @op_set_loc8
                ] do
        Closures.write_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          val,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )

        run(pc + 1, put_local(frame, idx, val), [val | rest], gas, ctx)
      end

      defp run({@op_set_loc_uninitialized, [idx]}, pc, frame, stack, gas, ctx) do
        Closures.write_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          :__tdz__,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )

        run(pc + 1, put_local(frame, idx, :__tdz__), stack, gas, ctx)
      end

      defp run({@op_get_loc_check, [idx]}, pc, frame, stack, gas, ctx) do
        raw = elem(elem(frame, Frame.locals()), idx)
        ensure_initialized_local!(ctx, idx, raw)

        val =
          Closures.read_captured_local(
            elem(frame, Frame.l2v()),
            idx,
            elem(frame, Frame.locals()),
            elem(frame, Frame.var_refs())
          )

        run(pc + 1, frame, [val | stack], gas, ctx)
      end

      defp run({@op_put_loc_check, [idx]}, pc, frame, [val | rest], gas, ctx) do
        ensure_initialized_local!(ctx, idx, val)

        Closures.write_captured_local(
          elem(frame, Frame.l2v()),
          idx,
          val,
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs())
        )

        run(pc + 1, put_local(frame, idx, val), rest, gas, ctx)
      end

      defp run({@op_put_loc_check_init, [idx]}, pc, frame, [val | rest], gas, ctx) do
        run(pc + 1, put_local(frame, idx, val), rest, gas, ctx)
      end

      defp run({@op_get_loc0_loc1, [idx0, idx1]}, pc, frame, stack, gas, ctx) do
        locals = elem(frame, Frame.locals())
        run(pc + 1, frame, [elem(locals, idx1), elem(locals, idx0) | stack], gas, ctx)
      end

      # ── Variable references (closures) ──

      defp run({op, [idx]}, pc, frame, stack, gas, ctx)
           when op in [
                  @op_get_var_ref,
                  @op_get_var_ref0,
                  @op_get_var_ref1,
                  @op_get_var_ref2,
                  @op_get_var_ref3
                ] do
        val =
          case elem(elem(frame, Frame.var_refs()), idx) do
            {:cell, _} = cell -> Closures.read_cell(cell)
            other -> other
          end

        run(pc + 1, frame, [val | stack], gas, ctx)
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
           when op in [
                  @op_put_var_ref,
                  @op_put_var_ref0,
                  @op_put_var_ref1,
                  @op_put_var_ref2,
                  @op_put_var_ref3
                ] do
        case elem(elem(frame, Frame.var_refs()), idx) do
          {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
          _ -> :ok
        end

        run(pc + 1, frame, rest, gas, ctx)
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, ctx)
           when op in [
                  @op_set_var_ref,
                  @op_set_var_ref0,
                  @op_set_var_ref1,
                  @op_set_var_ref2,
                  @op_set_var_ref3
                ] do
        case elem(elem(frame, Frame.var_refs()), idx) do
          {:cell, ref} -> Closures.write_cell({:cell, ref}, val)
          _ -> :ok
        end

        run(pc + 1, frame, [val | rest], gas, ctx)
      end

      defp run({@op_close_loc, [idx]}, pc, frame, stack, gas, ctx) do
        case Map.get(elem(frame, Frame.l2v()), idx) do
          nil ->
            run(pc + 1, frame, stack, gas, ctx)

          vref_idx ->
            vrefs = elem(frame, Frame.var_refs())
            old_cell = elem(vrefs, vref_idx)
            val = Closures.read_cell(old_cell)
            new_ref = make_ref()
            Heap.put_cell(new_ref, val)
            frame = put_elem(frame, Frame.var_refs(), put_elem(vrefs, vref_idx, {:cell, new_ref}))
            run(pc + 1, frame, stack, gas, ctx)
        end
      end
    end
  end
end
