defmodule QuickBEAM.VM.Interpreter.Completion do
  @moduledoc "Shared interpreter completion and context-refresh helpers."

  alias QuickBEAM.VM.{Heap, RuntimeState}
  alias QuickBEAM.VM.Interpreter.Context

  def current_context(ctx), do: RuntimeState.current_or(ctx)
  def refresh_globals(ctx), do: RuntimeState.refresh_globals(ctx)

  def refresh_persistent_globals(ctx) do
    case Heap.get_persistent_globals() do
      nil -> ctx
      p when map_size(p) == 0 -> ctx
      p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
    end
  end

  def throw_result(error, ctx), do: {:throw, error, current_context(ctx)}

  def capture(ctx, fun) when is_function(fun, 0) do
    try do
      {:ok, fun.(), refresh_globals(ctx)}
    catch
      {:js_throw, error} -> throw_result(error, ctx)
    end
  end
end
