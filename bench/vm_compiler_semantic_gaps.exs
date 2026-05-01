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
  {"dynamic import rejection", "import('x')"},
  {"derived constructor undefined return",
   "class A { constructor(){ this.a = 1 } } class B extends A { constructor(){ super(); return undefined } } new B().a"},
  {"derived constructor object return",
   "class A { constructor(){ this.a = 1 } } class B extends A { constructor(){ super(); return {b:2} } } new B().b"},
  {"with captured assignment",
   "var out; function f(){ let x=1; function g(){ let o={}; with(o){ x=2 } return x } return g() } f()"},
  {"with local fallback read", "let o={}; let x=1; with(o){ x }"},
  {"with delete property", "let o={x:1}; with(o){ delete x; } 'x' in o"},
  {"async await value", "async function f(){ return await 2 } f()"},
  {"async await resolved promise", "async function f(){ return await Promise.resolve(3) } f()"},
  {"generator two next values",
   "function* g(){ yield 1; yield 2; return 3 } let it=g(); it.next().value + it.next().value"},
  {"generator return value",
   "function* g(){ yield 1; return 3 } let it=g(); it.next(); it.next().value"},
  {"async caught throw", "async function f(){ try { throw 4 } catch(e) { return e } } f()"},
  {"with fallback method call", "function m(){return 3}; let o={}; with(o){ m() }"},
  {"with missing property delete", "let o={}; with(o){ delete x }"},
  {"with captured update",
   "function f(){ let x=1; function g(){ let o={}; with(o){ x++ } return x } return g() } f()"},
  {"with captured unscopables fallback",
   "function f(){ let x=1; function g(){ let o={x:2,[Symbol.unscopables]:{x:true}}; with(o){ x=3 } return [x,o.x] } return g() } f()"},
  {"async await chained promise",
   "async function f(){ return await Promise.resolve(1).then(function(v){ return v+1 }) } f()"},
  {"async nested await",
   "async function f(){ return await Promise.resolve(await Promise.resolve(4)) } f()"},
  {"async rejection catch",
   "async function f(){ return await Promise.reject('err').catch(function(e){ return e + '!' }) } f()"},
  {"generator third next value",
   "function* g(){ yield 1; yield 2; return 3 } let it=g(); it.next(); it.next(); it.next().value"},
  {"generator return method", "function* g(){ yield 1; yield 2 } let it=g(); it.return(9).value"},
  {"derived constructor new target",
   "class A { constructor(){ this.v = new.target.name } } class B extends A { constructor(){ super() } } new B().v"},
  {"computed class value invoked", "let o={ [class C{}]: 1 }; 1"},
  {"custom iterator loop value",
   "let it={ [Symbol.iterator](){ return { i:0, next(){ return this.i++ < 1 ? {value:7, done:false} : {done:true}; } } } }; let s=0; for (let x of it) s+=x; s"}
]

results =
  Enum.map(cases, fn {name, source} -> QuickBEAM.VM.CompilerAudit.run_case(name, source) end)

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
