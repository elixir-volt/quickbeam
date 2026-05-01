Mix.Task.run("app.start")

Code.require_file("../test/support/vm_compiler_audit.ex", __DIR__)

cases = [
  {"derived constructor primitive return",
   "class A { constructor(){ this.a = 1 } } class B extends A { constructor(){ super(); return 1 } } new B()"},
  {"with property assignment", "let o={x:1}; with(o){ x=2; } o.x"},
  {"with missing global assignment", "var x=1; let o={}; with(o){ x=2; } x"},
  {"with property update", "let o={x:1}; with(o){ x++; } o.x"},
  {"with unscopables fallback",
   "var x=1; let o={x:2, [Symbol.unscopables]: {x:true}}; with(o){ x=3; } [x,o.x]"},
  {"async function invocation", "async function f(){ return 1 } f()"},
  {"generator next value", "function* g(){ yield 1; return 2 } let it=g(); it.next().value"},
  {"dynamic import rejection", "import('x')"}
]

results = Enum.map(cases, fn {name, source} -> QuickBEAM.VM.CompilerAudit.run_case(name, source) end)
summary = QuickBEAM.VM.CompilerAudit.summary(results)
failures = summary.fallbacks + summary.crashes + summary.mismatches + summary.input_errors

IO.puts(
  "compiler_semantic_cases=#{summary.cases} compiler_semantic_compiled=#{summary.compiled} compiler_semantic_failures=#{failures} compiler_semantic_fallbacks=#{summary.fallbacks} compiler_semantic_crashes=#{summary.crashes} compiler_semantic_mismatches=#{summary.mismatches} compiler_semantic_input_errors=#{summary.input_errors}"
)

for result <- results, result.status != :compiled do
  IO.puts("COMPILER_SEMANTIC_#{String.upcase(to_string(result.status))} #{result.name}")
  IO.puts("  source=#{result.source}")
  IO.puts("  interpreter=#{inspect(result.interpreter)}")
  IO.puts("  compiler=#{inspect(result.compiler)}")
end

IO.puts("METRIC compiler_semantic_cases=#{summary.cases}")
IO.puts("METRIC compiler_semantic_compiled=#{summary.compiled}")
IO.puts("METRIC compiler_semantic_failures=#{failures}")
IO.puts("METRIC compiler_semantic_fallbacks=#{summary.fallbacks}")
IO.puts("METRIC compiler_semantic_crashes=#{summary.crashes}")
IO.puts("METRIC compiler_semantic_mismatches=#{summary.mismatches}")
IO.puts("METRIC compiler_semantic_input_errors=#{summary.input_errors}")
