Code.require_file("../test/support/js_compiler_audit.ex", __DIR__)

frontier_cases = [
  {"block let shadowing inner", "let x = 1; { let x = 2; x }"},
  {"block let shadowing outer", "let x = 1; { let x = 2; } x"},
  {"function var from block", "function f(){ if (true) { var x = 1; } return x; } f()"},
  {"function let block hidden", "function f(){ if (true) { let x = 1; } return typeof x; } f()"},
  {"closure captures parameter",
   "function make(x){ return function(y){ return x + y; }; } make(2)(3)"},
  {"closure captures local",
   "function make(){ let x = 2; return function(y){ return x + y; }; } make()(3)"},
  {"nested function declaration call",
   "function outer(){ function inner(){ return 4; } return inner(); } outer()"},
  {"switch default", "let x = 0; switch (2) { case 1: x = 1; break; default: x = 3; } x"},
  {"try catch value", "try { throw 3; } catch (e) { e + 1; }"},
  {"try finally value", "let x = 0; try { x = 1; } finally { x = x + 1; } x"},
  {"new constructor property", "function C(){ this.x = 3; } let c = new C(); c.x"},
  {"constructor prototype method",
   "function C(){} C.prototype.x = function(){ return 5; }; let c = new C(); c.x()"},
  {"array push method", "let a = []; a.push(1); a.length"},
  {"string charAt method", "\"abc\".charAt(1)"},
  {"logical assignment or", "let x = 0; x ||= 2; x"},
  {"logical assignment and", "let x = 1; x &&= 3; x"},
  {"logical assignment nullish", "let x = null; x ??= 4; x"},
  {"delete object property", "let o = {x: 1}; delete o.x; o.x"},
  {"in operator", "let o = {x: 1}; 'x' in o"},
  {"for in object", "let o = {a: 1, b: 2}; let s = ''; for (let k in o) { s = s + k; } s.length"}
]

results = QuickBEAM.JS.CompilerAudit.run(frontier_cases)
summary = QuickBEAM.JS.CompilerAudit.summary(results)

failures = summary.failures
mismatches = summary.mismatches
unsupported = summary.unsupported
compiled = summary.compiled
cases = summary.cases

IO.puts(
  "js_compiler_frontier_cases=#{cases} " <>
    "js_compiler_frontier_compiled=#{compiled} " <>
    "js_compiler_frontier_unsupported=#{unsupported} " <>
    "js_compiler_frontier_mismatches=#{mismatches} " <>
    "js_compiler_frontier_failures=#{failures}"
)

results
|> Enum.reject(&(&1.status == :pass))
|> Enum.take(String.to_integer(System.get_env("JS_COMPILER_FRONTIER_FAILURE_LIMIT", "12")))
|> Enum.each(fn result ->
  IO.puts("JS_COMPILER_FRONTIER_#{String.upcase(to_string(result.status))} #{result.name}")
  IO.puts("  source=#{result.source}")
  IO.puts("  expected=#{inspect(Map.get(result, :expected))}")
  IO.puts("  interpreter=#{inspect(Map.get(result, :interpreter))}")
  IO.puts("  compiler=#{inspect(Map.get(result, :compiler))}")
  IO.puts("  reason=#{inspect(Map.get(result, :reason))}")
end)

IO.puts("METRIC js_compiler_frontier_cases=#{cases}")
IO.puts("METRIC js_compiler_frontier_compiled=#{compiled}")
IO.puts("METRIC js_compiler_frontier_unsupported=#{unsupported}")
IO.puts("METRIC js_compiler_frontier_mismatches=#{mismatches}")
IO.puts("METRIC js_compiler_frontier_failures=#{failures}")
