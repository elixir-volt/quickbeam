Mix.Task.run("app.start")
Code.require_file("support/common.exs", __DIR__)
Code.require_file("../test/support/js_compiler_audit.ex", __DIR__)

results = QuickBEAM.JS.CompilerAudit.run()
summary = QuickBEAM.JS.CompilerAudit.summary(results)

IO.puts(
  "js_compiler_cases=#{summary.cases} js_compiler_compiled=#{summary.compiled} js_compiler_unsupported=#{summary.unsupported} js_compiler_mismatches=#{summary.mismatches} js_compiler_failures=#{summary.failures}"
)

for result <- results, result.status != :pass do
  IO.puts("JS_COMPILER_#{String.upcase(to_string(result.status))} #{result.name}")
  IO.puts("  source=#{result.source}")
  IO.puts("  expected=#{inspect(result.expected)}")
  IO.puts("  interpreter=#{inspect(Map.get(result, :interpreter))}")
  IO.puts("  compiler=#{inspect(Map.get(result, :compiler))}")
  IO.puts("  reason=#{inspect(Map.get(result, :reason))}")
end

Bench.Support.metrics(
  js_compiler_cases: summary.cases,
  js_compiler_compiled: summary.compiled,
  js_compiler_unsupported: summary.unsupported,
  js_compiler_mismatches: summary.mismatches,
  js_compiler_failures: summary.failures
)

if summary.failures != 0, do: System.halt(1)
