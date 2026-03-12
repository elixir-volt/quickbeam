defmodule SSR do
  @moduledoc """
  Server-side rendering with Preact and QuickBEAM.

  A pool of JS runtimes renders Preact components into a native DOM
  (lexbor). Elixir reads the DOM directly — no `renderToString`, no JSON
  round-trip, no Node.js.
  """

  @posts [
    %{
      slug: "beam-js-fusion",
      title: "When BEAM Met JavaScript",
      date: "2025-03-10",
      tags: ["elixir", "javascript"],
      excerpt: "JS runtimes as GenServers — isolated, supervised, observable.",
      body: "The BEAM gives you preemptive scheduling, fault tolerance, and hot code reloading. JavaScript gives you the largest package ecosystem on Earth. QuickBEAM fuses them: every JS runtime is an OTP process."
    },
    %{
      slug: "native-dom",
      title: "A Real DOM Without a Browser",
      date: "2025-03-08",
      tags: ["dom", "lexbor"],
      excerpt: "lexbor gives QuickBEAM a C-backed DOM tree — queryable from both JS and Elixir.",
      body: "Most JS-in-server solutions serialize HTML as strings. QuickBEAM keeps a live DOM tree backed by lexbor. JS mutates it with standard APIs; Elixir reads it with CSS selectors. Zero parsing overhead."
    },
    %{
      slug: "pool-rendering",
      title: "Pool-Based SSR",
      date: "2025-03-05",
      tags: ["ssr", "performance"],
      excerpt: "A NimblePool of JS runtimes handles concurrent render requests.",
      body: "Each runtime in the pool is initialized once with your Preact components. On checkout, it renders a page, Elixir extracts the HTML, and the runtime is reset for the next request. No cold starts after init."
    }
  ]

  @posts_by_slug Map.new(@posts, &{&1.slug, &1})

  def posts, do: @posts
  def get_post(slug), do: Map.get(@posts_by_slug, slug)

  @page_shell """
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><%= title %></title>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body { font-family: system-ui, sans-serif; line-height: 1.6; color: #1a1a1a; }
      body > div { max-width: 640px; margin: 0 auto; padding: 2rem 1rem; }
      nav { border-bottom: 1px solid #e5e5e5; padding-bottom: 1rem; margin-bottom: 2rem; }
      nav a { color: #0366d6; text-decoration: none; margin-right: 1rem; }
      h1 { margin-bottom: 1rem; }
      .post { margin-bottom: 2rem; padding-bottom: 1rem; border-bottom: 1px solid #f0f0f0; }
      .post h2 a { color: inherit; text-decoration: none; }
      .meta { color: #666; font-size: 0.875rem; margin-bottom: 1rem; }
      .tag { display: inline-block; background: #f0f0f0; padding: 0.125rem 0.5rem;
             border-radius: 3px; font-size: 0.75rem; margin-right: 0.25rem; }
    </style>
  </head>
  <body><%= body %></body>
  </html>
  """

  def render_page(pool, route, data \\ nil) do
    QuickBEAM.Pool.run(pool, fn rt ->
      QuickBEAM.call(rt, "renderPage", [route, data])

      {:ok, title} = QuickBEAM.dom_text(rt, "h1")
      {:ok, body_html} = QuickBEAM.eval(rt, "document.body.innerHTML")

      EEx.eval_string(@page_shell, title: title, body: body_html)
    end)
  end
end
