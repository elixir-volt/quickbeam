content_dir = Path.join(__DIR__, "priv/content")
output_dir = Path.join(__DIR__, "_site")

{:ok, rt} =
  QuickBEAM.start(
    script: Path.join(__DIR__, "priv/ts/build.ts"),
    apis: [:browser, :node],
    handlers: %{
      "log" => fn [%{"slug" => slug, "title" => title}] ->
        IO.puts("  #{slug}.html → #{title}")
      end
    }
  )

QuickBEAM.send_message(rt, %{contentDir: content_dir, outputDir: output_dir})
Process.sleep(1000)
