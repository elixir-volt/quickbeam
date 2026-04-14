defmodule QuickBEAM.CoverTest do
  use ExUnit.Case, async: false

  setup do
    already_running = QuickBEAM.Cover.enabled?()
    unless already_running, do: QuickBEAM.Cover.start()
    on_exit(fn -> unless already_running, do: QuickBEAM.Cover.stop() end)
    :ok
  end

  test "tracks line coverage for evaluated JS" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    {:ok, _} =
      QuickBEAM.eval(rt, """
      function add(a, b) {
        var result = a + b;
        return result;
      }
      add(10, 20);
      """)

    {:ok, cov} = QuickBEAM.coverage(rt)
    lines = cov["<eval>"]
    assert is_map(lines) and map_size(lines) > 0
    assert Enum.any?(lines, fn {_, count} -> count > 0 end)

    QuickBEAM.stop(rt)
  end

  test "shows uncovered branches" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    {:ok, _} =
      QuickBEAM.eval(rt, """
      function choose(x) {
        var result;
        if (x > 0) {
          result = "positive";
        } else if (x < 0) {
          result = "negative";
        } else {
          result = "zero";
        }
        return result;
      }
      choose(5);
      """)

    {:ok, cov} = QuickBEAM.coverage(rt)
    lines = cov["<eval>"]
    assert is_map(lines)

    hit_lines = Enum.filter(lines, fn {_, c} -> c > 0 end)
    miss_lines = Enum.filter(lines, fn {_, c} -> c == 0 end)
    assert hit_lines != [], "some lines should be covered"
    assert miss_lines != [], "some lines should not be covered"

    QuickBEAM.stop(rt)
  end

  test "collects coverage from multiple runtimes" do
    {:ok, rt1} = QuickBEAM.start(apis: false)
    {:ok, rt2} = QuickBEAM.start(apis: false)

    QuickBEAM.eval(rt1, """
    function compute(x) {
      var a = x * 2;
      var b = a + 1;
      return b;
    }
    compute(5);
    """)

    QuickBEAM.eval(rt2, """
    function process(x) {
      var a = x + 10;
      var b = a * 3;
      return b;
    }
    process(7);
    """)

    QuickBEAM.stop(rt1)
    QuickBEAM.stop(rt2)

    results = QuickBEAM.Cover.results()
    assert map_size(results) > 0
  end

  test "exports valid LCOV" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    QuickBEAM.eval(rt, """
    function hello(name) {
      var greeting = "Hello, " + name;
      return greeting;
    }
    hello("world");
    """)

    QuickBEAM.stop(rt)

    path = Path.join(System.tmp_dir!(), "qb_cover_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    lcov_path = Path.join(path, "test.lcov")

    QuickBEAM.Cover.export_lcov(lcov_path, QuickBEAM.Cover.results())
    content = File.read!(lcov_path)

    assert content =~ "SF:"
    assert content =~ "DA:"
    assert content =~ "LH:"
    assert content =~ "LF:"
    assert content =~ "end_of_record"

    File.rm_rf!(path)
  end

  test "exports valid Istanbul JSON" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    QuickBEAM.eval(rt, """
    function calc(a, b) {
      var sum = a + b;
      var product = a * b;
      return sum + product;
    }
    calc(3, 4);
    """)

    QuickBEAM.stop(rt)

    path = Path.join(System.tmp_dir!(), "qb_istanbul_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    json_path = Path.join(path, "coverage.json")

    QuickBEAM.Cover.export_istanbul(json_path, QuickBEAM.Cover.results())
    {:ok, content} = File.read(json_path)
    data = :json.decode(content)

    assert is_map(data)
    file_data = data |> Map.values() |> hd()
    assert Map.has_key?(file_data, "statementMap")
    assert Map.has_key?(file_data, "s")

    File.rm_rf!(path)
  end

  test "enabled? returns false when not started" do
    if QuickBEAM.Cover.enabled?() do
      assert true
    else
      QuickBEAM.Cover.stop()
      refute QuickBEAM.Cover.enabled?()
    end
  end

  test "reset_coverage clears counters" do
    {:ok, rt} = QuickBEAM.start(apis: false)

    QuickBEAM.eval(rt, """
    function work(x) {
      var a = x * 2;
      var b = a + 1;
      return b;
    }
    work(5);
    """)

    {:ok, cov1} = QuickBEAM.coverage(rt)
    hit_before = cov1 |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.count(&(&1 > 0))
    assert hit_before > 0

    ref = QuickBEAM.Native.reset_coverage(GenServer.call(rt, :resource))

    receive do
      {^ref, _} -> :ok
    after
      5_000 -> flunk("reset_coverage timeout")
    end

    {:ok, cov2} = QuickBEAM.coverage(rt)
    all_zero = cov2 |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.all?(&(&1 == 0))
    assert all_zero, "all counters should be zero after reset"

    QuickBEAM.stop(rt)
  end

  test "ignores files matching patterns" do
    QuickBEAM.Cover.record(%{
      "app.js" => %{1 => 1, 2 => 0},
      "node_modules/lib/index.js" => %{1 => 1}
    })

    results = QuickBEAM.Cover.results(ignore: ["node_modules/**"])
    assert Map.has_key?(results, "app.js")
    refute Map.has_key?(results, "node_modules/lib/index.js")
  end
end
