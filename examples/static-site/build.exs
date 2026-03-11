content_dir = Path.join(__DIR__, "priv/content")
output_dir = Path.join(__DIR__, "_site")

script = Path.join(__DIR__, "priv/ts/build.ts") |> Path.expand()
{:ok, code} = QuickBEAM.JS.Bundler.bundle_file(script)

{:ok, rt} =
  QuickBEAM.start(
    apis: [:browser, :node],
    define: %{"contentDir" => content_dir, "outputDir" => output_dir}
  )

{:ok, _} = QuickBEAM.eval(rt, code)
