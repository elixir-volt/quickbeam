defmodule SSR.PoolPlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:pool, opts[:pool])
    |> SSR.Router.call(SSR.Router.init([]))
  end
end
