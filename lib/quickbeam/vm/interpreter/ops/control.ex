defmodule QuickBEAM.VM.Interpreter.Ops.Control do
  @moduledoc "Control flow opcodes: if/goto/return, try/catch, gosub/ret, throw."

  @doc "Installs the Control flow opcodes: if/goto/return, try/catch, gosub/ret, throw helpers into the caller module."
  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Interpreter.Context
      alias QuickBEAM.VM.Semantics.Values
      alias QuickBEAM.VM.Semantics.Iterators

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
             [a, catch_target | rest],
             gas,
             %Context{catch_stack: [{catch_target, _} | rest_catch]} = ctx
           ) do
        run(
          pc + 1,
          frame,
          [a | rest],
          gas,
          Context.mark_dirty(%{ctx | catch_stack: rest_catch})
        )
      end

      defp run(
             {@op_nip_catch, []},
             pc,
             frame,
             [a, discard, catch_offset, next_fn, iter_obj | rest],
             gas,
             %Context{catch_stack: [_ | rest_catch]} = ctx
           )
           when is_integer(catch_offset) or catch_offset == :undefined do
        run_nip_catch_iterator(
          pc,
          frame,
          a,
          catch_offset,
          next_fn,
          iter_obj,
          rest,
          gas,
          ctx,
          rest_catch
        )
      end

      defp run(
             {@op_nip_catch, []},
             pc,
             frame,
             [a, _discard1, _discard2, catch_offset, next_fn, iter_obj | rest],
             gas,
             %Context{catch_stack: [_ | rest_catch]} = ctx
           )
           when is_integer(catch_offset) or catch_offset == :undefined do
        run_nip_catch_iterator(
          pc,
          frame,
          a,
          catch_offset,
          next_fn,
          iter_obj,
          rest,
          gas,
          ctx,
          rest_catch
        )
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

      defp run(
             {@op_nip_catch, []},
             pc,
             frame,
             [a, _discard, catch_offset, next_fn, iter_obj | rest],
             gas,
             ctx
           )
           when is_integer(catch_offset) or catch_offset == :undefined do
        run_nip_catch_iterator(
          pc,
          frame,
          a,
          catch_offset,
          next_fn,
          iter_obj,
          rest,
          gas,
          ctx,
          ctx.catch_stack
        )
      end

      defp run(
             {@op_nip_catch, []},
             pc,
             frame,
             [a, _discard1, _discard2, catch_offset, next_fn, iter_obj | rest],
             gas,
             ctx
           )
           when is_integer(catch_offset) or catch_offset == :undefined do
        run_nip_catch_iterator(
          pc,
          frame,
          a,
          catch_offset,
          next_fn,
          iter_obj,
          rest,
          gas,
          ctx,
          ctx.catch_stack
        )
      end

      defp run_nip_catch_iterator(
             pc,
             frame,
             a,
             catch_offset,
             next_fn,
             iter_obj,
             rest,
             gas,
             ctx,
             catch_stack
           ) do
        ctx = Context.mark_dirty(%{ctx | catch_stack: catch_stack})

        if QuickBEAM.VM.Builtin.callable?(next_fn) do
          run(pc + 1, frame, [a, next_fn, iter_obj | rest], gas, ctx)
        else
          run(pc + 1, frame, [a, catch_offset, iter_obj, next_fn | rest], gas, ctx)
        end
      end

      defp run({@op_nip_catch, []}, pc, frame, [a, _catch_offset | rest], gas, ctx) do
        run(pc + 1, frame, [a | rest], gas, ctx)
      end

      # ── gosub/ret (finally blocks) ──

      defp run(
             {@op_gosub, [target]},
             pc,
             frame,
             [completion | stack],
             gas,
             %Context{catch_stack: [{_catch_target, stack} | rest_catch]} = ctx
           ) do
        ctx = Context.mark_dirty(%{ctx | catch_stack: rest_catch})
        run(target, frame, [{:return_addr, pc + 1, rest_catch}, completion | stack], gas, ctx)
      end

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

      defp run({@op_throw, []}, _pc, frame, [val | rest], gas, ctx) do
        ctx = close_active_iterators_on_abrupt(rest, ctx)
        throw_or_catch(frame, val, gas, ctx)
      end

      defp close_active_iterators_on_abrupt(stack, ctx) do
        stack
        |> active_iterators_from_stack([])
        |> Enum.reduce(ctx, fn iter_obj, acc_ctx ->
          Iterators.iterator_close(acc_ctx, iter_obj)
          persistent = QuickBEAM.VM.Heap.get_persistent_globals() || %{}

          if map_size(persistent) == 0 do
            acc_ctx
          else
            Context.mark_dirty(%{acc_ctx | globals: Map.merge(acc_ctx.globals, persistent)})
          end
        end)
      catch
        {:js_throw, _close_error} -> ctx
      end

      defp active_iterators_from_stack([index, next_fn, iter_obj | rest], acc)
           when (is_integer(index) or index == :undefined) and next_fn != nil and
                  iter_obj != :undefined do
        active_iterators_from_stack(rest, [iter_obj | acc])
      end

      defp active_iterators_from_stack([_ | rest], acc),
        do: active_iterators_from_stack(rest, acc)

      defp active_iterators_from_stack([], acc), do: Enum.reverse(acc)
    end
  end
end
