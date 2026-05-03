Code.require_file("support/test262_files.exs", __DIR__)

defmodule Bench.JSParserPerf do
  @moduledoc false

  def run do
    inputs = load_inputs()
    repeat = Bench.Support.env_integer("PARSER_PERF_REPEAT", 1)

    best =
      1..repeat |> Enum.map(fn _run -> timed_parse(inputs) end) |> Enum.min_by(& &1.elapsed_us)

    failures = Enum.filter(best.results, &match?({:error, _, _}, &1.result))
    total_bytes = Enum.reduce(inputs, 0, &(&1.bytes + &2))
    total_ms = div(best.elapsed_us, 1_000)
    files_per_second = files_per_second(length(inputs), best.elapsed_us)

    IO.puts("files=#{length(inputs)}")
    IO.puts("bytes=#{total_bytes}")
    IO.puts("errors=#{length(failures)}")
    IO.puts("repeat=#{repeat}")
    IO.puts("total_ms=#{total_ms}")
    IO.puts("files_per_second=#{Float.round(files_per_second, 2)}")

    Enum.each(Enum.take(failures, 20), &print_failure/1)

    Bench.Support.metrics(
      total_ms: total_ms,
      parser_files: length(inputs),
      parser_bytes: total_bytes,
      parser_errors: length(failures),
      parser_files_per_second: Float.round(files_per_second, 2),
      parser_perf_repeats: repeat
    )

    if failures != [], do: System.halt(1)
  end

  defp load_inputs do
    Enum.map(Bench.Test262Files.sample(), fn path ->
      source = File.read!(path)

      %{
        path: path,
        source: source,
        bytes: byte_size(source),
        source_type: Bench.Test262Files.source_type(path, source)
      }
    end)
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

  defp print_failure(%{path: path, result: {:error, _program, errors}}) do
    first = hd(errors)

    IO.puts(
      "ERROR_FILE #{path} #{first.line}:#{first.column} #{first.message} total=#{length(errors)}"
    )
  end

  defp files_per_second(_count, 0), do: 0.0
  defp files_per_second(count, elapsed_us), do: count * 1_000_000 / elapsed_us
end

Bench.JSParserPerf.run()
