defmodule CounterLive.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>QuickBEAM Counter</title>
      <script defer phx-track-static src={"https://cdn.jsdelivr.net/npm/phoenix@1.7.20/priv/static/phoenix.min.js"}></script>
      <script defer phx-track-static src={"https://cdn.jsdelivr.net/npm/phoenix_live_view@1.0.9/priv/static/phoenix_live_view.min.js"}></script>
      <script>
        window.addEventListener("phx:page-loading-stop", () => {
          const lv = window.liveSocket
          if (!lv) {
            const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket)
            liveSocket.connect()
            window.liveSocket = liveSocket
          }
        })
      </script>
    </head>
    <body style="margin: 0; background: #fff;">
      {@inner_content}
    </body>
    </html>
    """
  end
end
