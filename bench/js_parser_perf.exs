defmodule ParserPerfBench do
  @moduledoc false

  @default_sample_limit 60_000
  @default_test262_glob "test/test262/test/**/*.js"

  def run do
    inputs = load_inputs()
    repeat = repeat_count()

    runs = Enum.map(1..repeat, fn _run -> timed_parse(inputs) end)
    best = Enum.min_by(runs, & &1.elapsed_us)

    failures = Enum.filter(best.results, &match?({:error, _, _}, &1.result))
    total_bytes = Enum.reduce(inputs, 0, &(&1.bytes + &2))
    total_ms = div(best.elapsed_us, 1_000)

    files_per_second =
      if best.elapsed_us == 0, do: 0.0, else: length(inputs) * 1_000_000 / best.elapsed_us

    IO.puts("files=#{length(inputs)}")
    IO.puts("bytes=#{total_bytes}")
    IO.puts("errors=#{length(failures)}")
    IO.puts("repeat=#{repeat}")
    IO.puts("total_ms=#{total_ms}")
    IO.puts("files_per_second=#{Float.round(files_per_second, 2)}")

    Enum.take(failures, 20)
    |> Enum.each(fn %{path: path, result: {:error, _program, errors}} ->
      first = hd(errors)

      IO.puts(
        "ERROR_FILE #{path} #{first.line}:#{first.column} #{first.message} total=#{length(errors)}"
      )
    end)

    IO.puts("METRIC total_ms=#{total_ms}")
    IO.puts("METRIC parser_files=#{length(inputs)}")
    IO.puts("METRIC parser_bytes=#{total_bytes}")
    IO.puts("METRIC parser_errors=#{length(failures)}")
    IO.puts("METRIC parser_files_per_second=#{Float.round(files_per_second, 2)}")
    IO.puts("METRIC parser_perf_repeats=#{repeat}")

    if failures == [], do: :ok, else: System.halt(1)
  end

  defp timed_parse(inputs) do
    {elapsed_us, results} =
      :timer.tc(fn ->
        Enum.map(inputs, fn input ->
          result = QuickBEAM.JS.Parser.parse(input.source, source_type: input.source_type)
          %{path: input.path, result: result}
        end)
      end)

    %{elapsed_us: elapsed_us, results: results}
  end

  defp load_inputs do
    sample_files()
    |> Enum.map(fn path ->
      source = File.read!(path)

      %{
        path: path,
        source: source,
        bytes: byte_size(source),
        source_type: source_type(path, source)
      }
    end)
  end

  defp sample_files do
    test262_glob()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reject(&negative_test?/1)
    |> Enum.drop(sample_offset())
    |> Enum.take(sample_limit())
    |> Enum.reject(&support_fixture?/1)
  end

  defp source_type(path, source) do
    cond do
      metadata_module?(source) -> :module
      script_code_fixture?(path) -> :script
      String.contains?(path, "/module-code/") -> :module
      static_module_syntax?(source) -> :module
      true -> :script
    end
  end

  defp metadata_module?(source) do
    Regex.match?(~r/flags:\s*\[[^\]]*\bmodule\b/, source)
  end

  defp script_code_fixture?(path), do: String.contains?(Path.basename(path), "script-code")

  defp static_module_syntax?(source) do
    Regex.match?(~r/^\s*import\s+(?:[\w*{]|["'])/m, source) or
      Regex.match?(~r/^\s*export\s+/m, source)
  end

  defp negative_test?(path) do
    path |> File.read!() |> String.contains?("negative:")
  end

  defp support_fixture?(path), do: String.ends_with?(path, "_FIXTURE.js")

  defp test262_glob, do: System.get_env("TEST262_GLOB", @default_test262_glob)
  defp sample_limit, do: env_integer("TEST262_SAMPLE_LIMIT", @default_sample_limit)
  defp sample_offset, do: env_integer("TEST262_SAMPLE_OFFSET", 0)
  defp repeat_count, do: env_integer("PARSER_PERF_REPEAT", 1)

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end

ParserPerfBench.run()
