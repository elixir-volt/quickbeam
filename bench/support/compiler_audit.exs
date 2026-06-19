Code.require_file("common.exs", __DIR__)
Code.require_file("../../test/support/vm_compiler_audit.ex", __DIR__)

defmodule Bench.CompilerAudit do
  @moduledoc false

  def run(cases_fun, metric_prefix, label_prefix) do
    results =
      Enum.map(cases_fun.(), fn {name, source} ->
        QuickBEAM.VM.CompilerAudit.run_case(name, source)
      end)

    print(results, QuickBEAM.VM.CompilerAudit.summary(results), metric_prefix, label_prefix)
  end

  def run_all(metric_prefix, label_prefix) do
    results = QuickBEAM.VM.CompilerAudit.run_all()
    print(results, QuickBEAM.VM.CompilerAudit.summary(results), metric_prefix, label_prefix)
  end

  defp print(results, summary, metric_prefix, label_prefix) do
    IO.puts(
      "#{metric_prefix}_cases=#{summary.cases} #{metric_prefix}_compiled=#{summary.compiled} #{metric_prefix}_fallbacks=#{summary.fallbacks} #{metric_prefix}_crashes=#{summary.crashes} #{metric_prefix}_mismatches=#{summary.mismatches} #{metric_prefix}_input_errors=#{summary.input_errors}"
    )

    results
    |> Enum.filter(&(&1.status in [:mismatch, :crash, :compile_input_error]))
    |> Enum.each(&print_failure(&1, label_prefix))

    summary.fallback_reasons
    |> Enum.sort_by(fn {_reason, count} -> -count end)
    |> Enum.each(fn {reason, count} ->
      IO.puts("#{label_prefix}_FALLBACK count=#{count} reason=#{reason}")
    end)

    Bench.Support.metrics([
      {"#{metric_prefix}_cases", summary.cases},
      {"#{metric_prefix}_compiled", summary.compiled},
      {"#{metric_prefix}_fallbacks", summary.fallbacks},
      {"#{metric_prefix}_crashes", summary.crashes},
      {"#{metric_prefix}_mismatches", summary.mismatches},
      {"#{metric_prefix}_input_errors", summary.input_errors}
    ])
  end

  defp print_failure(result, label_prefix) do
    IO.puts("#{label_prefix}_#{String.upcase(to_string(result.status))} #{result.name}")
    IO.puts("  source=#{result.source}")
    IO.puts("  interpreter=#{inspect(result.interpreter)}")
    IO.puts("  compiler=#{inspect(result.compiler)}")
  end
end
