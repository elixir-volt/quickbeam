defmodule QuickBEAM.VM.Interpreter.Ops.Control do
  @moduledoc "Control flow opcodes: if/goto/return, try/catch, gosub/ret, throw."

  @doc "Installs the Control flow opcodes: if/goto/return, try/catch, gosub/ret, throw helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.{Context, Values}

      # ── Control flow ──

      defp run({op, [target]}, pc, frame, [val | rest], gas, ctx)
           when op in [@op_if_false, @op_if_false8] do
        if Values.falsy?(val) do
          gas = if target <= pc, do: check_gas(pc, frame, rest, gas, ctx), else: gas
          run(target, frame, rest, gas, ctx)
        else
          run(pc + 1, frame, rest, gas, ctx)
        end
      end

      defp run({op, [target]}, pc, frame, [val | rest], gas, ctx)
           when op in [@op_if_true, @op_if_true8] do
        if Values.truthy?(val) do
          gas = if target <= pc, do: check_gas(pc, frame, rest, gas, ctx), else: gas
          run(target, frame, rest, gas, ctx)
        else
          run(pc + 1, frame, rest, gas, ctx)
        end
      end

      defp run({op, [target]}, __pc, frame, stack, gas, ctx)
           when op in [@op_goto, @op_goto8, @op_goto16] do
        run(target, frame, stack, gas, ctx)
      end

      defp run({@op_return, []}, _pc, _frame, [val | _], _gas, _ctx), do: val

      defp run({@op_return_undef, []}, _pc, _frame, _stack, _gas, _ctx), do: :undefined

      # ── try/catch ──

      defp run(
             {@op_catch, [target]},
             pc,
             frame,
             stack,
             gas,
             %Context{catch_stack: catch_stack} = ctx
           ) do
        ctx =
          Context.mark_dirty(%{
            ctx
            | catch_stack: [{target, stack} | catch_stack]
          })

        run(pc + 1, frame, [target | stack], gas, ctx)
      end

      defp run(
             {@op_nip_catch, []},
             pc,
             frame,
             [a, _catch_offset | rest],
             gas,
             %Context{catch_stack: [_ | rest_catch]} = ctx
           ) do
        run(
          pc + 1,
          frame,
          [a | rest],
          gas,
          Context.mark_dirty(%{ctx | catch_stack: rest_catch})
        )
      end

      # ── gosub/ret (finally blocks) ──

      defp run({@op_gosub, [target]}, pc, frame, stack, gas, %{catch_stack: []} = ctx) do
        run(target, frame, [{:return_addr, pc + 1} | stack], gas, ctx)
      end

      defp run({@op_gosub, [target]}, pc, frame, stack, gas, ctx) do
        run(target, frame, [{:return_addr, pc + 1, ctx.catch_stack} | stack], gas, ctx)
      end

      defp run({@op_ret, []}, __pc, frame, [{:return_addr, ret_pc, saved_cs} | rest], gas, ctx) do
        ctx = trim_catch_stack(ctx, saved_cs)
        run(ret_pc, frame, rest, gas, ctx)
      end

      defp run({@op_ret, []}, __pc, frame, [{:return_addr, ret_pc} | rest], gas, ctx) do
        run(ret_pc, frame, rest, gas, ctx)
      end

      # ── throw ──

      defp run({@op_throw, []}, _pc, frame, [val | _], gas, ctx) do
        throw_or_catch(frame, val, gas, ctx)
      end
    end
  end
end
