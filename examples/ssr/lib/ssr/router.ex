defmodule SSR.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  def init(opts), do: opts

  get "/" do
    html = SSR.render_page(conn.private.pool, "index", SSR.posts())
    send_html(conn, 200, html)
  end

  get "/post/:slug" do
    case SSR.get_post(slug) do
      nil -> send_html(conn, 404, SSR.render_page(conn.private.pool, "not_found"))
      post -> send_html(conn, 200, SSR.render_page(conn.private.pool, "post", post))
    end
  end

  get "/about" do
    send_html(conn, 200, SSR.render_page(conn.private.pool, "about"))
  end

  match _ do
    send_html(conn, 404, SSR.render_page(conn.private.pool, "not_found"))
  end

  defp send_html(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end
end
