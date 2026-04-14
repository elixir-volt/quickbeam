defmodule QuickBEAM.Cover do
  @moduledoc """
  JavaScript coverage tool for `mix test --cover`.

  Reports line-level coverage for all JS/TS code executed through
  QuickBEAM runtimes during the test suite, alongside standard
  Elixir coverage.

  ## Setup

      # mix.exs
      def project do
        [
          ...,
          test_coverage: [tool: QuickBEAM.Cover]
        ]
      end

  Then run:

      $ mix test --cover

  Elixir coverage works as normal (delegates to Erlang's `:cover`).
  JS coverage is collected automatically from all QuickBEAM runtimes
  that start during the test run.

  ## Options

  Accepts all standard `:test_coverage` options, plus:

    * `:js` — keyword list of JS-specific options:
      * `:ignore` — file patterns to exclude (default: `["node_modules/**"]`)

  ## Using with excoveralls

  If you already use excoveralls, add JS coverage as a sidecar:

      # test/test_helper.exs
      QuickBEAM.Cover.start()
      ExUnit.after_suite(fn _ -> QuickBEAM.Cover.stop() end)

  JS coverage is written to `cover/js_lcov.info`.
  """

  @table __MODULE__

  @doc false
  def start(compile_path, opts) when is_binary(compile_path) do
    erlang_callback = Mix.Tasks.Test.Coverage.start(compile_path, opts)

    start()

    fn ->
      if erlang_callback, do: erlang_callback.()

      js_opts = Keyword.get(opts, :js, [])
      output = Keyword.get(opts, :output, "cover")
      summary_opts = Keyword.get(opts, :summary, threshold: 90)

      data =
        stop(
          output: output,
          ignore: Keyword.get(js_opts, :ignore, ["node_modules/**"])
        )

      if summary_opts != false do
        threshold =
          if is_list(summary_opts),
            do: Keyword.get(summary_opts, :threshold, 90),
            else: 90

        print_summary(data, threshold)
      end
    end
  end

  @spec start() :: :ok
  def start do
    :ets.new(@table, [:named_table, :public, :set])
    :persistent_term.put({__MODULE__, :enabled}, true)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec stop(keyword()) :: map()
  def stop(opts \\ []) do
    output = Keyword.get(opts, :output, "cover")
    ignore = Keyword.get(opts, :ignore, ["node_modules/**"])

    data = results(ignore: ignore)

    if map_size(data) > 0 do
      File.mkdir_p!(output)
      export_lcov(Path.join(output, "js_lcov.info"), data)
    end

    :persistent_term.erase({__MODULE__, :enabled})

    if :ets.info(@table) != :undefined do
      :ets.delete(@table)
    end

    data
  rescue
    ArgumentError -> %{}
  end

  @spec enabled?() :: boolean()
  def enabled? do
    :persistent_term.get({__MODULE__, :enabled}, false)
  end

  @doc false
  @spec record(map()) :: :ok
  def record(coverage_map) when is_map(coverage_map) do
    if :ets.info(@table) != :undefined do
      Enum.each(coverage_map, fn {filename, lines} when is_map(lines) ->
        Enum.each(lines, fn {line, count} ->
          line = if is_binary(line), do: String.to_integer(line), else: line
          count = if is_integer(count), do: max(count, 0), else: 0
          :ets.update_counter(@table, {filename, line}, {2, count}, {{filename, line}, 0})
        end)
      end)
    end

    :ok
  end

  @spec results(keyword()) :: map()
  def results(opts \\ []) do
    ignore = Keyword.get(opts, :ignore, [])

    if :ets.info(@table) == :undefined do
      %{}
    else
      :ets.tab2list(@table)
      |> Enum.group_by(
        fn {{filename, _line}, _count} -> filename end,
        fn {{_filename, line}, count} -> {line, count} end
      )
      |> Enum.reject(fn {filename, _} -> ignored?(filename, ignore) end)
      |> Map.new(fn {filename, lines} -> {filename, Map.new(lines)} end)
    end
  end

  @spec export_lcov(Path.t(), map()) :: :ok
  def export_lcov(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, to_lcov(data))
  end

  @spec export_istanbul(Path.t(), map()) :: :ok
  def export_istanbul(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :json.encode(to_istanbul(data)))
  end

  defp ignored?(_filename, []), do: false

  defp ignored?(filename, patterns) do
    Enum.any?(patterns, fn pattern ->
      regex =
        pattern
        |> String.replace(".", "\\.")
        |> String.replace("**", "\0")
        |> String.replace("*", "[^/]*")
        |> String.replace("\0", ".*")

      String.match?(filename, ~r/^#{regex}$/)
    end)
  end

  defp to_lcov(data) do
    data
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {filename, lines} ->
      sorted = Enum.sort_by(lines, &elem(&1, 0))
      covered = Enum.count(sorted, fn {_, c} -> c > 0 end)

      [
        "SF:",
        filename,
        "\n",
        Enum.map(sorted, fn {line, count} ->
          ["DA:", to_string(line), ",", to_string(count), "\n"]
        end),
        "LH:",
        to_string(covered),
        "\n",
        "LF:",
        to_string(length(sorted)),
        "\n",
        "end_of_record\n"
      ]
    end)
    |> IO.iodata_to_binary()
  end

  defp to_istanbul(data) do
    Map.new(data, fn {filename, lines} ->
      sorted = Enum.sort_by(lines, &elem(&1, 0))

      statement_map =
        sorted
        |> Enum.with_index()
        |> Map.new(fn {{line, _}, idx} ->
          {to_string(idx),
           %{
             "start" => %{"line" => line, "column" => 0},
             "end" => %{"line" => line, "column" => 999}
           }}
        end)

      s =
        sorted
        |> Enum.with_index()
        |> Map.new(fn {{_, count}, idx} -> {to_string(idx), count} end)

      {filename,
       %{
         "path" => filename,
         "statementMap" => statement_map,
         "fnMap" => %{},
         "branchMap" => %{},
         "s" => s,
         "f" => %{},
         "b" => %{}
       }}
    end)
  end

  defp print_summary(data, threshold) do
    if map_size(data) > 0, do: do_print_summary(data, threshold)
  end

  defp do_print_summary(data, threshold) do
    IO.puts("")

    rows =
      data
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {filename, lines} ->
        total = map_size(lines)
        covered = Enum.count(lines, fn {_, c} -> c > 0 end)
        pct = if total > 0, do: covered / total * 100.0, else: 100.0
        {filename, pct}
      end)

    max_name =
      rows |> Enum.map(fn {n, _} -> String.length(n) end) |> Enum.max(fn -> 4 end) |> max(4)

    IO.puts(String.pad_leading("Percentage", 10) <> " | File")
    IO.puts(String.duplicate("-", 11) <> "|" <> String.duplicate("-", max_name + 2))

    Enum.each(rows, fn {filename, pct} ->
      color = if pct >= threshold, do: :green, else: :red
      pct_str = :io_lib.format(~c"~8.2f%", [pct]) |> IO.iodata_to_binary()

      IO.ANSI.format([color, pct_str, :reset, " | ", filename])
      |> IO.iodata_to_binary()
      |> IO.puts()
    end)

    all_counts = Enum.flat_map(data, fn {_, lines} -> Map.values(lines) end)

    total_pct =
      if all_counts == [],
        do: 100.0,
        else: Enum.count(all_counts, &(&1 > 0)) / length(all_counts) * 100.0

    total_color = if total_pct >= threshold, do: :green, else: :red

    IO.puts(String.duplicate("-", 11) <> "|" <> String.duplicate("-", max_name + 2))

    IO.ANSI.format([
      total_color,
      :io_lib.format(~c"~8.2f%", [total_pct]) |> IO.iodata_to_binary(),
      :reset,
      " | Total (JavaScript)"
    ])
    |> IO.iodata_to_binary()
    |> IO.puts()
  end
end
