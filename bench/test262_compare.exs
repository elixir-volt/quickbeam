#!/usr/bin/env elixir
# Compare test262 pass rates: QuickJS NIF vs BEAM Compiler vs BEAM Interpreter
#
# Usage: MIX_ENV=test mix run bench/test262_compare.exs [dir_pattern]

defmodule Test262Compare do
  @test262_dir Path.expand("../../quickjs/test262", __DIR__)
  @harness_dir Path.join(@test262_dir, "harness")

  def run(dir_pattern \\ "language/expressions") do
    test_dir = Path.join(@test262_dir, "test/#{dir_pattern}")

    unless File.dir?(test_dir) do
      IO.puts("Directory not found: #{test_dir}")
      System.halt(1)
    end

    {:ok, rt} = QuickBEAM.start(apis: false, mode: :beam)

    harness = load_harness()
    tests = find_tests(test_dir)
    IO.puts("Found #{length(tests)} test files in #{dir_pattern}\n")

    results = %{nif: %{pass: 0, fail: 0, error: 0, skip: 0},
                compiler: %{pass: 0, fail: 0, error: 0, skip: 0},
                interpreter: %{pass: 0, fail: 0, error: 0, skip: 0}}

    {total_time, results} = :timer.tc(fn ->
      Enum.reduce(tests, results, fn test_file, acc ->
        case parse_test(test_file) do
          {:skip, _reason} ->
            update_all(acc, :skip)

          {:ok, metadata, source} ->
            full_source = build_source(harness, metadata, source)
            run_test(acc, rt, full_source, metadata)
        end
      end)
    end)

    QuickBEAM.stop(rt)

    IO.puts("\n\n=== Results for #{dir_pattern} (#{length(tests)} tests, #{div(total_time, 1000)}ms) ===\n")
    for {mode, stats} <- results do
      total = stats.pass + stats.fail + stats.error
      pct = if total > 0, do: Float.round(stats.pass / total * 100, 1), else: 0.0
      IO.puts("#{String.pad_trailing(Atom.to_string(mode), 12)} pass=#{stats.pass} fail=#{stats.fail} error=#{stats.error} skip=#{stats.skip}  (#{pct}%)")
    end
  end

  defp load_harness do
    assert_js = File.read!(Path.join(@harness_dir, "assert.js"))
    sta_js = File.read!(Path.join(@harness_dir, "sta.js"))

    test262error = """
    function Test262Error(message) {
      this.message = message || "";
      this.name = "Test262Error";
    }
    Test262Error.prototype.toString = function() {
      return "Test262Error: " + this.message;
    };
    """

    %{assert: assert_js, sta: sta_js, test262error: test262error}
  end

  defp find_tests(dir) do
    Path.wildcard(Path.join(dir, "**/*.js"))
    |> Enum.reject(&String.contains?(&1, "_FIXTURE"))
    |> Enum.sort()
  end

  defp parse_test(file) do
    source = File.read!(file)

    # Extract YAML metadata
    case Regex.run(~r|/\*---\n(.*?)\n---\*/|s, source) do
      [_, yaml] ->
        features = extract_list(yaml, "features")
        flags = extract_list(yaml, "flags")
        includes = extract_list(yaml, "includes")
        negative = extract_negative(yaml)

        # Skip tests with unsupported features
        unsupported = ["SharedArrayBuffer", "Atomics", "Temporal",
                       "import-assertions", "import-attributes",
                       "decorators", "regexp-v-flag", "symbols-as-weakmap-keys",
                       "ShadowRealm", "iterator-helpers", "explicit-resource-management",
                       "resizable-arraybuffer", "arraybuffer-transfer",
                       "Float16Array", "uint8array-base64",
                       "source-phase-imports", "import-defer",
                       "RegExp.escape", "json-parse-with-source",
                       "import-text", "import-bytes"]

        if Enum.any?(features, &(&1 in unsupported)) do
          {:skip, "unsupported feature"}
        else if "async" in flags do
          {:skip, "async"}
        else if "module" in flags do
          {:skip, "module"}
        else
          {:ok, %{features: features, flags: flags, includes: includes,
                  negative: negative, raw: flags}, source}
        end end end

      _ ->
        {:ok, %{features: [], flags: [], includes: [], negative: nil, raw: []}, source}
    end
  end

  defp extract_list(yaml, key) do
    case Regex.run(~r/#{key}:\s*\n((?:\s+-\s+.*\n?)+)/m, yaml) do
      [_, list_str] ->
        Regex.scan(~r/-\s+(.+)/, list_str)
        |> Enum.map(fn [_, v] -> String.trim(v) end)
      _ -> []
    end
  end

  defp extract_negative(yaml) do
    case Regex.run(~r/negative:\s*\n\s+phase:\s+(\w+)\s*\n\s+type:\s+(\w+)/m, yaml) do
      [_, phase, type] -> %{phase: phase, type: type}
      _ -> nil
    end
  end

  defp build_source(harness, metadata, test_source) do
    includes = Enum.map(metadata.includes, fn inc ->
      path = Path.join(@harness_dir, inc)
      if File.exists?(path), do: File.read!(path), else: ""
    end)

    [harness.test262error, harness.sta, harness.assert | includes]
    |> Enum.join("\n")
    |> Kernel.<>("\n" <> test_source)
  end

  defp run_test(acc, rt, source, metadata) do
    expects_error = metadata.negative != nil and metadata.negative.phase in ["parse", "runtime"]

    # NIF
    nif_result = run_nif(rt, source, expects_error)
    acc = update_in(acc, [:nif, result_key(nif_result)], &(&1 + 1))

    # Only run BEAM modes if NIF can compile the source
    case QuickBEAM.compile(rt, "(function(){ #{source} \n})") do
      {:ok, _bc} ->
        compiler_result = run_beam(rt, source, :beam, expects_error)
        interpreter_result = run_beam(rt, source, :interpreter, expects_error)
        acc = update_in(acc, [:compiler, result_key(compiler_result)], &(&1 + 1))
        update_in(acc, [:interpreter, result_key(interpreter_result)], &(&1 + 1))

      {:error, _} ->
        if expects_error do
          acc = update_in(acc, [:compiler, :pass], &(&1 + 1))
          update_in(acc, [:interpreter, :pass], &(&1 + 1))
        else
          acc = update_in(acc, [:compiler, :error], &(&1 + 1))
          update_in(acc, [:interpreter, :error], &(&1 + 1))
        end
    end
  end

  defp run_nif(rt, source, expects_error) do
    try do
      case QuickBEAM.eval(rt, source) do
        {:ok, _} -> if expects_error, do: :fail, else: :pass
        {:error, %{name: name}} ->
          if expects_error, do: :pass, else: :fail
        {:error, _} -> if expects_error, do: :pass, else: :fail
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp run_beam(rt, source, mode, expects_error) do
    try do
      wrapped = "(function(){ #{source} \n})"
      case QuickBEAM.eval(rt, wrapped, mode: mode) do
        {:ok, _} -> if expects_error, do: :fail, else: :pass
        {:error, %{name: name}} ->
          if expects_error, do: :pass, else: :fail
        {:error, _} -> if expects_error, do: :pass, else: :fail
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp result_key(:pass), do: :pass
  defp result_key(:fail), do: :fail
  defp result_key(:error), do: :error

  defp update_all(acc, key) do
    acc
    |> update_in([:nif, key], &(&1 + 1))
    |> update_in([:compiler, key], &(&1 + 1))
    |> update_in([:interpreter, key], &(&1 + 1))
  end
end

dir = List.first(System.argv()) || "language/expressions"
Test262Compare.run(dir)
