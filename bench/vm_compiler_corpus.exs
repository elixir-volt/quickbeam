Mix.Task.run("app.start")

Code.require_file("../test/support/vm_compiler_audit.ex", __DIR__)

binary_ops = [
  "+",
  "-",
  "*",
  "/",
  "%",
  "<",
  "<=",
  ">",
  ">=",
  "===",
  "!==",
  "&",
  "|",
  "^",
  "<<",
  ">>",
  ">>>"
]

values = ["-3", "-1", "0", "1", "2", "5", "'2'", "true", "false", "null"]

binary_cases =
  for op <- binary_ops,
      left <- values,
      right <- values,
      not (op in ["/", "%"] and right == "0") do
    {"binary #{left} #{op} #{right}", "#{left} #{op} #{right}"}
  end

statement_cases = [
  {"nested loops",
   "let s = 0; for (let i = 0; i < 4; i++) { for (let j = 0; j < 3; j++) s += i + j; } s"},
  {"switch default",
   "let x = 3; let y = 0; switch (x) { case 1: y = 1; break; default: y = 9; } y"},
  {"try finally", "let x = 1; try { x = 2; } finally { x = x + 3; } x"},
  {"catch rethrow avoided", "let x = 0; try { throw 5; } catch (e) { x = e; } x"},
  {"object mutation", "let o = {}; o.x = 1; o.y = o.x + 2; o"},
  {"array mutation", "let a = []; a[0] = 1; a[2] = 3; a"},
  {"method this update", "let o = {x: 1, inc() { this.x++; return this.x; }}; o.inc() + o.inc()"},
  {"closure mutation",
   "function make(){ let x = 0; return function(){ x++; return x; }; } let f = make(); f() + f()"},
  {"constructor fields", "function A(x) { this.x = x; } let a = new A(4); a.x"},
  {"class static", "class A { static x = 3; static m() { return this.x + 1; } } A.m()"},
  {"spread call", "function f(a, b, c) { return a + b + c; } f(...[1, 2, 3])"},
  {"rest args", "function f(...xs) { return xs[0] + xs.length; } f(4, 5)"},
  {"default param", "function f(x = 3) { return x; } f() + f(2)"},
  {"destructured param", "function f({x}, [y]) { return x + y; } f({x: 1}, [2])"},
  {"computed object key", "let k = 'x'; let o = {[k]: 5}; o.x"},
  {"template expression", "let x = 4; `a${x + 1}`"},
  {"regexp replace", "'aa'.replace(/a/g, 'b')"},
  {"array map", "[1, 2, 3].map(x => x + 1).join(',')"},
  {"optional call", "let o = { f() { return 7; } }; o.f?.()"},
  {"nullish assignment", "let x = null; x ??= 4; x"}
]

cases = QuickBEAM.VM.CompilerAudit.cases() ++ Enum.take(binary_cases, 160) ++ statement_cases

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
