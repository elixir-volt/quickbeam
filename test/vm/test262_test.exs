defmodule QuickBEAM.VM.Test262Test do
  use ExUnit.Case, async: false

  @moduletag :test262
  @manifest_path Path.expand("../test262/manifest.exs", __DIR__)
  @manifest QuickBEAM.Test262.load_manifest(@manifest_path)
  @root QuickBEAM.Test262.configured_root()

  test "parses bounded Test262 metadata" do
    source = """
    /*---
    flags: [onlyStrict]
    includes: [compareArray.js]
    features:
      - async-functions
    negative:
      phase: runtime
      type: TypeError
    ---*/
    """

    assert %{
             flags: ["onlyStrict"],
             includes: ["compareArray.js"],
             features: ["async-functions"],
             negative: %{phase: :runtime, type: "TypeError"}
           } = QuickBEAM.Test262.parse_metadata(source)
  end

  test "summarizes supported results without counting explicit skips" do
    assert is_list(@manifest[:tests])

    results = [
      %{classification: :pass},
      %{classification: :vm_failure},
      %{classification: :unsupported_flag},
      %{classification: :missing}
    ]

    assert %{
             total: 4,
             supported: 2,
             pass_rate: 0.5,
             counts: %{pass: 1, vm_failure: 1, unsupported_flag: 1, missing: 1}
           } = QuickBEAM.Test262.summarize(results)
  end

  if @root do
    @tag timeout: 120_000
    test "selected manifest meets its pinned differential conformance threshold" do
      {revision, 0} = System.cmd("git", ["-C", @root, "rev-parse", "HEAD"])
      assert String.trim(revision) == @manifest[:revision]

      results = QuickBEAM.Test262.run_manifest(@root, @manifest)
      summary = QuickBEAM.Test262.summarize(results)

      failures =
        Enum.filter(results, &(&1.classification in [:missing, :native_failure, :vm_failure]))

      actual_vm_failures =
        results
        |> Enum.filter(&(&1.classification == :vm_failure))
        |> Enum.map(& &1.path)
        |> MapSet.new()

      expected_vm_failures = @manifest[:known_failures] |> Map.keys() |> MapSet.new()

      assert actual_vm_failures == expected_vm_failures, failure_message(summary, failures)

      assert summary.pass_rate >= @manifest[:minimum_pass_rate],
             failure_message(summary, failures)

      refute Enum.any?(results, &(&1.classification == :missing)),
             failure_message(summary, failures)

      refute Enum.any?(results, &(&1.classification == :native_failure)),
             failure_message(summary, failures)
    end

    defp failure_message(summary, failures) do
      details =
        Enum.map_join(failures, "\n", fn result ->
          "#{result.classification}: #{result.path}\n  VM: #{inspect(result.vm, limit: 8)}\n  native: #{inspect(result.native, limit: 8)}"
        end)

      "Test262 summary: #{inspect(summary)}\n#{details}"
    end
  else
    @tag skip: "set TEST262_PATH to the pinned Test262 checkout"
    test "selected manifest meets its pinned differential conformance threshold" do
    end
  end
end
