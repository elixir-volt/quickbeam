defmodule QuickBEAM.VM.Interpreter.Ops.SpecialObjects do
  @moduledoc "Interpreter helpers for QuickJS special-object bytecodes."

  alias QuickBEAM.VM.Interpreter.{ArgumentsObject, Context}
  alias QuickBEAM.VM.Semantics.Construction

  def build(type, frame, %Context{} = ctx) do
    %Context{arg_buf: arg_buf, current_func: current_func, home_object: home_object} = ctx

    value =
      case type do
        type when type in [0, 1] ->
          ArgumentsObject.get(ctx, frame)

        _ ->
          Construction.special_object(type, current_func, arg_buf, ctx.new_target, home_object)
      end

    ctx =
      if type in [0, 1] do
        ArgumentsObject.store_global(ctx, value)
      else
        ctx
      end

    {value, ctx}
  end
end
