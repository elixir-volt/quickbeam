defmodule SSRTest do
  use ExUnit.Case

  setup_all do
    script = Path.join(File.cwd!(), "priv/js/app.js") |> Path.expand()
    {:ok, code} = QuickBEAM.JS.Bundler.bundle_file(script)

    {:ok, pool} =
      QuickBEAM.Pool.start_link(
        size: 2,
        init: fn rt -> QuickBEAM.eval(rt, code) end
      )

    %{pool: pool}
  end

  test "renders index with all posts", %{pool: pool} do
    html = SSR.render_page(pool, "index", SSR.posts())

    assert html =~ "<h1>Blog</h1>"
    assert html =~ "When BEAM Met JavaScript"
    assert html =~ "A Real DOM Without a Browser"
    assert html =~ "Pool-Based SSR"
    assert html =~ ~s(href="/post/beam-js-fusion")
  end

  test "renders post detail", %{pool: pool} do
    post = SSR.get_post("native-dom")
    html = SSR.render_page(pool, "post", post)

    assert html =~ "<title>A Real DOM Without a Browser</title>"
    assert html =~ "live DOM tree backed by lexbor"
    assert html =~ ~s(class="tag")
  end

  test "renders 404 for unknown route", %{pool: pool} do
    html = SSR.render_page(pool, "not_found")

    assert html =~ "<title>404</title>"
    assert html =~ "Page not found"
  end

  test "renders about page", %{pool: pool} do
    html = SSR.render_page(pool, "about")

    assert html =~ "Preact inside QuickBEAM"
    assert html =~ "No Node.js"
  end

  test "concurrent renders don't interfere", %{pool: pool} do
    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          Enum.random([
            fn -> SSR.render_page(pool, "index", SSR.posts()) end,
            fn -> SSR.render_page(pool, "post", SSR.get_post("native-dom")) end,
            fn -> SSR.render_page(pool, "about") end
          ]).()
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.all?(results, &is_binary/1)
    assert Enum.all?(results, &(&1 =~ "<!DOCTYPE html>"))
  end

  test "pool renders use DOM introspection for title", %{pool: pool} do
    html = SSR.render_page(pool, "post", SSR.get_post("beam-js-fusion"))
    assert html =~ "<title>When BEAM Met JavaScript</title>"

    html = SSR.render_page(pool, "about")
    assert html =~ "<title>About</title>"
  end
end
