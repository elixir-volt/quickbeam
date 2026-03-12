script = Path.join(__DIR__, "priv/js/app.js") |> Path.expand()
{:ok, code} = QuickBEAM.JS.Bundler.bundle_file(script)

{:ok, pool} =
  QuickBEAM.Pool.start_link(
    name: SSR.Pool,
    size: 4,
    init: fn rt -> QuickBEAM.eval(rt, code) end
  )

IO.puts("SSR pool started (4 runtimes)")
IO.puts("http://localhost:4000\n")

{:ok, _} = Bandit.start_link(plug: {SSR.PoolPlug, pool: pool}, port: 4000)

Process.sleep(:infinity)
