Mix.Task.run("app.start")

Code.require_file("../test/support/vm_compiler_audit.ex", __DIR__)

cases = QuickBEAM.VM.CompilerAudit.corpus_cases()

results =
  Enum.map(cases, fn {name, source} -> QuickBEAM.VM.CompilerAudit.run_case(name, source) end)

summary = QuickBEAM.VM.CompilerAudit.summary(results)

IO.puts(
  "compiler_corpus_cases=#{summary.cases} compiler_corpus_compiled=#{summary.compiled} compiler_corpus_fallbacks=#{summary.fallbacks} compiler_corpus_crashes=#{summary.crashes} compiler_corpus_mismatches=#{summary.mismatches} compiler_corpus_input_errors=#{summary.input_errors}"
)

for result <- results, result.status in [:mismatch, :crash, :compile_input_error] do
  IO.puts("COMPILER_CORPUS_#{String.upcase(to_string(result.status))} #{result.name}")
  IO.puts("  source=#{result.source}")
  IO.puts("  interpreter=#{inspect(result.interpreter)}")
  IO.puts("  compiler=#{inspect(result.compiler)}")
end

for {reason, count} <- Enum.sort_by(summary.fallback_reasons, fn {_reason, count} -> -count end) do
  IO.puts("COMPILER_CORPUS_FALLBACK count=#{count} reason=#{reason}")
end

IO.puts("METRIC compiler_corpus_cases=#{summary.cases}")
IO.puts("METRIC compiler_corpus_compiled=#{summary.compiled}")
IO.puts("METRIC compiler_corpus_fallbacks=#{summary.fallbacks}")
IO.puts("METRIC compiler_corpus_crashes=#{summary.crashes}")
IO.puts("METRIC compiler_corpus_mismatches=#{summary.mismatches}")
IO.puts("METRIC compiler_corpus_input_errors=#{summary.input_errors}")
