Mix.Task.run("app.start")

Code.require_file("../test/support/vm_compiler_audit.ex", __DIR__)

results = QuickBEAM.VM.CompilerAudit.run_all()
summary = QuickBEAM.VM.CompilerAudit.summary(results)

IO.puts(
  "compiler_cases=#{summary.cases} compiler_compiled=#{summary.compiled} compiler_fallbacks=#{summary.fallbacks} compiler_crashes=#{summary.crashes} compiler_mismatches=#{summary.mismatches}"
)

for result <- results, result.status in [:mismatch, :crash, :compile_input_error] do
  IO.puts("COMPILER_#{String.upcase(to_string(result.status))} #{result.name}")
  IO.puts("  source=#{result.source}")
  IO.puts("  interpreter=#{inspect(result.interpreter)}")
  IO.puts("  compiler=#{inspect(result.compiler)}")
end

for {reason, count} <- Enum.sort_by(summary.fallback_reasons, fn {_reason, count} -> -count end) do
  IO.puts("COMPILER_FALLBACK count=#{count} reason=#{reason}")
end

IO.puts("METRIC compiler_cases=#{summary.cases}")
IO.puts("METRIC compiler_compiled=#{summary.compiled}")
IO.puts("METRIC compiler_fallbacks=#{summary.fallbacks}")
IO.puts("METRIC compiler_crashes=#{summary.crashes}")
IO.puts("METRIC compiler_mismatches=#{summary.mismatches}")
