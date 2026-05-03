Code.require_file("support/test262_files.exs", __DIR__)

defmodule Bench.JSParserCompat do
  @moduledoc false

  @test_language_path "test/vm/test_language.js"
  @default_error_limit 40

  def run do
    test_language = parse_file(@test_language_path, :script)
    sample = Bench.Test262Files.sample()
    results = Enum.map(sample, &parse_sample_file/1)

    print_summary(test_language, results)
    print_error_clusters(results)
    print_error_files(results)
    print_metrics(test_language, results)
  end

  defp parse_sample_file(path) do
    source = File.read!(path)
    parse_source(path, source, Bench.Test262Files.source_type(path, source))
  end

  defp parse_file(path, source_type), do: parse_source(path, File.read!(path), source_type)

  defp parse_source(path, source, source_type) do
    case QuickBEAM.JS.Parser.parse(source, source_type: source_type) do
      {:ok, _program} ->
        %{path: path, source_type: source_type, status: :ok, errors: []}

      {:error, _program, errors} ->
        %{path: path, source_type: source_type, status: :error, errors: errors}
    end
  end

  defp print_summary(test_language, results) do
    IO.puts("case,status,errors,unique_messages,files,error_files")

    IO.puts(
      "test_language,#{test_language.status},#{length(test_language.errors)},#{length(unique_messages([test_language]))},1,#{if test_language.status == :error, do: 1, else: 0}"
    )

    IO.puts(
      "test262_language_sample,#{sample_status(results)},#{error_count(results)},#{length(unique_messages(results))},#{length(results)},#{length(failures(results))}"
    )
  end

  defp print_error_clusters(results) do
    results
    |> failures()
    |> Enum.flat_map(fn result -> Enum.map(result.errors, & &1.message) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {message, count} -> {-count, message} end)
    |> Enum.take(20)
    |> Enum.each(fn {message, count} -> IO.puts("ERROR_MESSAGE #{count} #{message}") end)

    results
    |> failures()
    |> Enum.map(&directory_bucket/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {bucket, count} -> {-count, bucket} end)
    |> Enum.take(20)
    |> Enum.each(fn {bucket, count} -> IO.puts("ERROR_DIR #{count} #{bucket}") end)
  end

  defp print_error_files(results) do
    results
    |> failures()
    |> Enum.take(error_limit())
    |> Enum.each(fn result ->
      first = hd(result.errors)

      IO.puts(
        "ERROR_FILE #{result.path} #{first.line}:#{first.column} #{first.message} total=#{length(result.errors)} source_type=#{result.source_type}"
      )
    end)
  end

  defp print_metrics(test_language, results) do
    Bench.Support.metrics(
      test262_language_sample_errors: error_count(results),
      test262_language_sample_error_files: length(failures(results)),
      test262_language_sample_unique_errors: length(unique_messages(results)),
      test262_language_sample_files: length(results),
      test262_language_sample_module_files: Enum.count(results, &(&1.source_type == :module)),
      test_language_errors: length(test_language.errors),
      test_language_unique_errors: length(unique_messages([test_language])),
      test_language_parse_ok: if(test_language.status == :ok, do: 1, else: 0)
    )
  end

  defp failures(results), do: Enum.filter(results, &(&1.status == :error))

  defp error_count(results),
    do: results |> failures() |> Enum.map(&length(&1.errors)) |> Enum.sum()

  defp unique_messages(results) do
    results
    |> failures()
    |> Enum.flat_map(fn result -> Enum.map(result.errors, & &1.message) end)
    |> Enum.uniq()
  end

  defp sample_status(results),
    do: if(Enum.any?(results, &(&1.status == :error)), do: :error, else: :ok)

  defp directory_bucket(%{path: path}), do: path |> Path.split() |> Enum.take(6) |> Path.join()

  defp error_limit, do: Bench.Support.env_integer("TEST262_ERROR_LIMIT", @default_error_limit)
end

Bench.JSParserCompat.run()
