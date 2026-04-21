defmodule QuickBEAM.VM.Interpreter.Gas do
  @moduledoc false

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Frame

  require Frame

  def check(frame, stack, gas, ctx, interval) do
    gas = gas - 1

    if gas <= 0 do
      throw({:error, {:out_of_gas, gas}})
    end

    if rem(gas, interval) == 0 and Heap.gc_needed?() do
      roots =
        [
          elem(frame, Frame.locals()),
          elem(frame, Frame.var_refs()),
          elem(frame, Frame.constants()),
          ctx.this,
          ctx.current_func,
          ctx.arg_buf,
          ctx.catch_stack,
          ctx.globals
          | stack
        ] ++ Heap.all_module_exports()

      Heap.mark_and_sweep(roots)
    end

    gas
  end
end
