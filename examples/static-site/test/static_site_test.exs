defmodule StaticSiteTest do
  use ExUnit.Case

  @content_dir Path.join(__DIR__, "../priv/content") |> Path.expand()

  setup do
    output_dir = Path.join(System.tmp_dir!(), "quickbeam_static_site_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(output_dir)
    on_exit(fn -> File.rm_rf!(output_dir) end)
    {:ok, output_dir: output_dir}
  end

  test "generates HTML from markdown", %{output_dir: output_dir} do
    {:ok, rt} =
      QuickBEAM.start(
        script: Path.join(__DIR__, "../priv/ts/build.ts") |> Path.expand(),
        apis: [:browser, :node],
        handlers: %{
          "log" => fn _ -> :ok end
        }
      )

    QuickBEAM.send_message(rt, %{contentDir: @content_dir, outputDir: output_dir})
    Process.sleep(2000)

    assert File.exists?(Path.join(output_dir, "index.html"))
    assert File.exists?(Path.join(output_dir, "hello-world.html"))
    assert File.exists?(Path.join(output_dir, "beam-vs-node.html"))
    refute File.exists?(Path.join(output_dir, "draft-post.html"))

    hello = File.read!(Path.join(output_dir, "hello-world.html"))
    assert hello =~ "<strong>BEAM</strong>"
    assert hello =~ "<title>Hello World</title>"
    assert hello =~ ~s(<a href="https://oxc.rs">OXC</a>)

    index = File.read!(Path.join(output_dir, "index.html"))
    assert index =~ "hello-world.html"
    assert index =~ "beam-vs-node.html"
    refute index =~ "draft-post"
  end
end
