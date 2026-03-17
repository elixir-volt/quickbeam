defmodule CounterLive.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :put_root_layout, html: {CounterLive.Layouts, :root}
  end

  scope "/", CounterLive do
    pipe_through :browser
    live "/", Counter
  end
end
