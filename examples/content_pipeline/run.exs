js_dir = Path.join(__DIR__, "priv/js") |> Path.expand()
{:ok, _sup} = ContentPipeline.start_link(collector: self(), js_dir: js_dir)

posts = [
  %{
    id: 1,
    title: "Getting Started with QuickBEAM",
    body: """
    ## Installation

    Add QuickBEAM to your `mix.exs`:

    ```elixir
    {:quickbeam, "~> 0.2.0"}
    ```

    ## Quick start

    Each runtime is a [GenServer](https://hexdocs.pm/elixir/GenServer.html):

    ```elixir
    {:ok, rt} = QuickBEAM.start()
    {:ok, 42} = QuickBEAM.eval(rt, "40 + 2")
    ```

    See the [full docs](https://hexdocs.pm/quickbeam) for more.
    """
  },
  %{
    id: 2,
    title: "Buy Now! Free Money!!!",
    body: "Click here for $$$ — act now! **Limited offer** just for you!"
  },
  %{
    id: 3,
    title: "BEAM vs Node.js",
    body: """
    The BEAM gives you:

    - Preemptive scheduling
    - Per-process GC
    - Hot code reloading

    > No event loop starvation.
    """
  }
]

for post <- posts, do: ContentPipeline.submit(post)

for _ <- posts do
  receive do
    {:done, result} ->
      spam = if result["is_spam"], do: " [SPAM]", else: ""
      IO.puts("#{result["id"]}#{spam} | #{result["title"]}")
      IO.puts("  #{result["word_count"]} words · #{result["reading_time"]} min read")
      IO.puts("  headings: #{inspect(Enum.map(result["headings"], & &1["text"]))}")
      IO.puts("  links: #{length(result["links"])} · code blocks: #{length(result["code_blocks"])}")
      IO.puts("")
  after
    5_000 -> IO.puts("timeout")
  end
end
