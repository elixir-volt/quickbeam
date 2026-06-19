defmodule QuickBEAM.VM.Interpreter.Ops.RestArguments do
  @moduledoc "Rest-argument opcode handlers."

  defmacro __using__(_opts) do
    quote location: :keep do
      alias QuickBEAM.VM.Heap
      alias QuickBEAM.VM.Interpreter.Context

      defp run({@op_rest, [start_idx]}, pc, frame, stack, gas, %Context{arg_buf: arg_buf} = ctx) do
        rest_args =
          if start_idx < tuple_size(arg_buf) do
            Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
          else
            []
          end

        ref = make_ref()
        Heap.put_obj(ref, rest_args)
        run(pc + 1, frame, [{:obj, ref} | stack], gas, ctx)
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, %Context{} = ctx)
           when op in [@op_put_arg, @op_put_arg0, @op_put_arg1, @op_put_arg2, @op_put_arg3] do
        run_arg_update(pc, frame, rest, gas, ctx, idx, val)
      end

      defp run({op, [idx]}, pc, frame, [val | rest], gas, %Context{} = ctx)
           when op in [@op_set_arg, @op_set_arg0, @op_set_arg1, @op_set_arg2, @op_set_arg3] do
        run_arg_update(pc, frame, [val | rest], gas, ctx, idx, val)
      end
    end
  end
end
