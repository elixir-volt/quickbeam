defmodule ContentPipelineTest do
  use ExUnit.Case

  setup do
    js_dir = Path.join(File.cwd!(), "priv/js")
    start_supervised!({ContentPipeline, collector: self(), js_dir: js_dir})
    :ok
  end

  test "parses markdown to HTML" do
    ContentPipeline.submit(%{id: 1, title: "Test", body: "**bold** and _italic_"})

    assert_receive {:done, result}, 2000
    assert result["html"] =~ "<strong>bold</strong>"
    assert result["html"] =~ "<em>italic</em>"
  end

  test "extracts headings from markdown" do
    ContentPipeline.submit(%{
      id: 2,
      title: "Headings",
      body: "## First\n\nText\n\n### Second\n\nMore text"
    })

    assert_receive {:done, result}, 2000
    headings = result["headings"]
    assert length(headings) == 2
    assert Enum.at(headings, 0)["text"] == "First"
    assert Enum.at(headings, 0)["level"] == 2
    assert Enum.at(headings, 1)["text"] == "Second"
    assert Enum.at(headings, 1)["level"] == 3
  end

  test "extracts links" do
    ContentPipeline.submit(%{
      id: 3,
      title: "Links",
      body: "Visit [Elixir](https://elixir-lang.org) and [Erlang](https://erlang.org)."
    })

    assert_receive {:done, result}, 2000
    links = result["links"]
    assert length(links) == 2
    hrefs = Enum.map(links, & &1["href"])
    assert "https://elixir-lang.org" in hrefs
    assert "https://erlang.org" in hrefs
  end

  test "extracts code blocks with language" do
    ContentPipeline.submit(%{
      id: 4,
      title: "Code",
      body: "```elixir\nIO.puts(\"hello\")\nIO.puts(\"world\")\n```"
    })

    assert_receive {:done, result}, 2000
    blocks = result["code_blocks"]
    assert length(blocks) == 1
    assert Enum.at(blocks, 0)["lang"] == "elixir"
    assert Enum.at(blocks, 0)["lines"] >= 2
  end

  test "counts words and reading time" do
    words = String.duplicate("word ", 400) |> String.trim()

    ContentPipeline.submit(%{id: 5, title: "Long", body: words})

    assert_receive {:done, result}, 2000
    assert result["word_count"] == 400
    assert result["reading_time"] == 2
  end

  test "detects spam" do
    ContentPipeline.submit(%{
      id: 6,
      title: "Buy Now! Free Money!!!",
      body: "Click here for $$$ — act now!"
    })

    assert_receive {:done, result}, 2000
    assert result["is_spam"] == true
    assert result["spam_score"] >= 2
  end

  test "passes clean content" do
    ContentPipeline.submit(%{id: 7, title: "Clean Post", body: "Just a normal post."})

    assert_receive {:done, result}, 2000
    assert result["is_spam"] == false
    assert result["spam_score"] == 0
  end

  test "adds processing timestamp" do
    ContentPipeline.submit(%{id: 8, title: "T", body: "B"})

    assert_receive {:done, result}, 2000
    assert is_binary(result["processed_at"])
    assert {:ok, _, _} = DateTime.from_iso8601(result["processed_at"])
  end

  test "processes multiple posts concurrently" do
    for i <- 1..10 do
      ContentPipeline.submit(%{id: i, title: "Post #{i}", body: "Content #{i}"})
    end

    results =
      for _ <- 1..10 do
        assert_receive {:done, result}, 2000
        result
      end

    ids = results |> Enum.map(& &1["id"]) |> Enum.sort()
    assert ids == Enum.to_list(1..10)
  end

  test "supervisor restarts crashed stage" do
    ContentPipeline.submit(%{id: 0, title: "before", body: "test"})
    assert_receive {:done, _}, 2000

    analyzer_pid = Process.whereis(:analyzer)
    Process.exit(analyzer_pid, :kill)
    Process.sleep(200)

    assert Process.whereis(:analyzer) != analyzer_pid
    assert Process.whereis(:parser) != nil
    assert Process.whereis(:enricher) != nil
  end
end
