script = Path.join(__DIR__, "priv/js/app.jsx") |> Path.expand()
{:ok, code} = QuickBEAM.JS.Bundler.bundle_file(script, jsx: :classic, jsx_factory: "createElement")

{:ok, pool} =
  QuickBEAM.Pool.start_link(
    name: SSR.Pool,
    size: 4,
    max_stack_size: 2 * 1024 * 1024,
    init: fn rt -> QuickBEAM.eval(rt, code) end
  )

IO.puts("SSR pool started (4 runtimes)")
IO.puts("http://localhost:4000\n")

{:ok, _} = Bandit.start_link(plug: {SSR.PoolPlug, pool: pool}, port: 4000)

Process.sleep(:infinity)
