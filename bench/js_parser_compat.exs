defmodule ParserCompatBench do
  @moduledoc false

  @default_sample_limit 12_000
  @default_error_limit 40
  @language_glob "test/test262/test/language/**/*.js"
  @test_language_path "test/vm/test_language.js"

  def run do
    test_language_result = parse_file(@test_language_path, :script)
    sample_files = sample_files()
    sample_results = Enum.map(sample_files, &parse_sample_file/1)

    print_summary(test_language_result, sample_results)
    print_error_clusters(sample_results)
    print_error_files(sample_results)
    print_metrics(test_language_result, sample_results)
  end

  defp sample_files do
    @language_glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reject(&negative_test?/1)
    |> Enum.drop(sample_offset())
    |> Enum.take(sample_limit())
    |> Enum.reject(&support_fixture?/1)
  end

  defp parse_sample_file(path) do
    source = File.read!(path)
    parse_source(path, source, source_type(path, source))
  end

  defp parse_file(path, source_type) do
    parse_source(path, File.read!(path), source_type)
  end

  defp parse_source(path, source, source_type) do
    case QuickBEAM.JS.Parser.parse(source, source_type: source_type) do
      {:ok, _program} ->
        %{path: path, source_type: source_type, status: :ok, errors: []}

      {:error, _program, errors} ->
        %{path: path, source_type: source_type, status: :error, errors: errors}
    end
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

  defp print_summary(test_language_result, sample_results) do
    test_language_errors = test_language_result.errors
    test_language_messages = unique_messages([test_language_result])
    sample_failures = failures(sample_results)

    IO.puts("case,status,errors,unique_messages,files,error_files")

    IO.puts(
      "test_language,#{test_language_result.status},#{length(test_language_errors)},#{length(test_language_messages)},1,#{if test_language_result.status == :error, do: 1, else: 0}"
    )

    IO.puts(
      "test262_language_sample,#{sample_status(sample_results)},#{error_count(sample_results)},#{length(unique_messages(sample_results))},#{length(sample_results)},#{length(sample_failures)}"
    )
  end

  defp print_error_clusters(sample_results) do
    sample_results
    |> failures()
    |> Enum.flat_map(fn result -> Enum.map(result.errors, & &1.message) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {message, count} -> {-count, message} end)
    |> Enum.take(20)
    |> Enum.each(fn {message, count} ->
      IO.puts("ERROR_MESSAGE #{count} #{message}")
    end)

    sample_results
    |> failures()
    |> Enum.map(&directory_bucket/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {bucket, count} -> {-count, bucket} end)
    |> Enum.take(20)
    |> Enum.each(fn {bucket, count} ->
      IO.puts("ERROR_DIR #{count} #{bucket}")
    end)
  end

  defp print_error_files(sample_results) do
    sample_results
    |> failures()
    |> Enum.take(error_limit())
    |> Enum.each(fn result ->
      first = hd(result.errors)

      IO.puts(
        "ERROR_FILE #{result.path} #{first.line}:#{first.column} #{first.message} total=#{length(result.errors)} source_type=#{result.source_type}"
      )
    end)
  end

  defp print_metrics(test_language_result, sample_results) do
    sample_failures = failures(sample_results)

    IO.puts("METRIC test262_language_sample_errors=#{error_count(sample_results)}")
    IO.puts("METRIC test262_language_sample_error_files=#{length(sample_failures)}")

    IO.puts(
      "METRIC test262_language_sample_unique_errors=#{length(unique_messages(sample_results))}"
    )

    IO.puts("METRIC test262_language_sample_files=#{length(sample_results)}")
    IO.puts("METRIC test262_language_sample_module_files=#{module_count(sample_results)}")
    IO.puts("METRIC test_language_errors=#{length(test_language_result.errors)}")

    IO.puts(
      "METRIC test_language_unique_errors=#{length(unique_messages([test_language_result]))}"
    )

    IO.puts(
      "METRIC test_language_parse_ok=#{if test_language_result.status == :ok, do: 1, else: 0}"
    )
  end

  defp failures(results), do: Enum.filter(results, &(&1.status == :error))

  defp error_count(results) do
    results |> failures() |> Enum.map(&length(&1.errors)) |> Enum.sum()
  end

  defp unique_messages(results) do
    results
    |> failures()
    |> Enum.flat_map(fn result -> Enum.map(result.errors, & &1.message) end)
    |> Enum.uniq()
  end

  defp sample_status(results) do
    if Enum.any?(results, &(&1.status == :error)), do: :error, else: :ok
  end

  defp module_count(results), do: Enum.count(results, &(&1.source_type == :module))

  defp directory_bucket(%{path: path}) do
    path
    |> Path.split()
    |> Enum.take(6)
    |> Path.join()
  end

  defp sample_limit, do: env_integer("TEST262_SAMPLE_LIMIT", @default_sample_limit)
  defp sample_offset, do: env_integer("TEST262_SAMPLE_OFFSET", 0)
  defp error_limit, do: env_integer("TEST262_ERROR_LIMIT", @default_error_limit)

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end

ParserCompatBench.run()
