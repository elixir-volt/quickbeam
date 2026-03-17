defmodule CounterLive.Counter do
  use Phoenix.LiveView

  @script Path.expand("../../priv/js/counter.ts", __DIR__)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, ctx} = QuickBEAM.Context.start_link(
      pool: CounterLive.JSPool,
      script: @script,
      apis: false
    )

    {:ok, count} = QuickBEAM.Context.call(ctx, "getCount")
    {:ok, assign(socket, ctx: ctx, count: count)}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    {:ok, count} = QuickBEAM.Context.call(socket.assigns.ctx, "increment")
    {:noreply, assign(socket, count: count)}
  end

  def handle_event("decrement", _params, socket) do
    {:ok, count} = QuickBEAM.Context.call(socket.assigns.ctx, "decrement")
    {:noreply, assign(socket, count: count)}
  end

  def handle_event("reset", _params, socket) do
    {:ok, count} = QuickBEAM.Context.call(socket.assigns.ctx, "reset")
    {:noreply, assign(socket, count: count)}
  end

  def handle_event("add", %{"amount" => amount}, socket) do
    {n, _} = Integer.parse(amount)
    {:ok, count} = QuickBEAM.Context.call(socket.assigns.ctx, "increment", [n])
    {:noreply, assign(socket, count: count)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui, sans-serif; max-width: 400px; margin: 80px auto; text-align: center;">
      <h1 style="font-size: 24px; margin-bottom: 8px;">QuickBEAM Counter</h1>
      <p style="color: #64748b; font-size: 14px; margin-bottom: 32px;">
        Each session gets its own ~58 KB JS context from a shared pool.
      </p>

      <div style="font-size: 72px; font-weight: 700; margin: 24px 0;">
        {@count}
      </div>

      <div style="display: flex; gap: 8px; justify-content: center;">
        <button phx-click="decrement" style={btn_style()}>−</button>
        <button phx-click="reset" style={btn_style()}>Reset</button>
        <button phx-click="increment" style={btn_style()}>+</button>
      </div>

      <form phx-submit="add" style="margin-top: 24px; display: flex; gap: 8px; justify-content: center;">
        <input name="amount" type="number" value="10" style="width: 80px; padding: 8px; border: 1px solid #cbd5e1; border-radius: 6px; text-align: center;" />
        <button type="submit" style={btn_style()}>Add</button>
      </form>
    </div>
    """
  end

  defp btn_style do
    "padding: 10px 20px; font-size: 18px; border: 1px solid #cbd5e1; border-radius: 8px; background: #f8fafc; cursor: pointer;"
  end
end
