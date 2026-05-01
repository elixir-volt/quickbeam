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
   "let it={ [Symbol.iterator](){ return { i:0, next(){ return this.i++ < 1 ? {value:7, done:false} : {done:true}; } } } }; let s=0; for (let x of it) s+=x; s"},
  {"with fallback delete global", "var x=1; let o={}; with(o){ delete x } x"},
  {"with unscopables read fallback",
   "var x=1; let o={x:2,[Symbol.unscopables]:{x:true}}; with(o){ x }"},
  {"async multiple awaits sum",
   "async function f(){ let a=await 1; let b=await 2; return a+b } f()"},
  {"async promise all length",
   "async function f(){ let r = await Promise.all([Promise.resolve(1), Promise.resolve(2)]); return r.length } f()"},
  {"generator next done flag", "function* g(){ yield 1 } let it=g(); it.next(); it.next().done"},
  {"generator send ignored first",
   "function* g(){ let x = yield 1; return x } let it=g(); it.next(5).value"},
  {"generator send second",
   "function* g(){ let x = yield 1; return x } let it=g(); it.next(); it.next(7).value"},
  {"derived super argument",
   "class A { constructor(x){ this.x=x } } class B extends A { constructor(){ super(5) } } new B().x"},
  {"super method call",
   "class A { m(){ return 1 } } class B extends A { m(){ return super.m()+1 } } new B().m()"},
  {"private field method", "class A { #x=1; m(){ return this.#x } } new A().m()"},
  {"array destructuring default", "let [a=3] = []; a"},
  {"object spread override", "let o={...{x:1}, x:2}; o.x"},
  {"optional chain method", "let o={x:1,m(){return this.x}}; o?.m()"},
  {"nullish assignment", "let x=null; x ??= 3; x"},
  {"logical assignment", "let x=0; x ||= 4; x"},
  {"regexp exec group", "/(a+)/.exec('aa')[1]"},
  {"typed array value", "let a=new Uint8Array(2); a[0]=255; a[0]"},
  {"map set get", "let m=new Map(); m.set('x', 2); m.get('x')"},
  {"set has", "let s=new Set(); s.add(3); s.has(3)"},
  {"string includes", "'quickbeam'.includes('beam')"},
  {"array map length", "[1,2,3].map(function(x){return x+1}).length"},
  {"array reduce sum", "[1,2,3].reduce(function(a,b){return a+b},0)"},
  {"object keys length", "Object.keys({a:1,b:2}).length"},
  {"json stringify object", "JSON.stringify({a:1})"},
  {"date now type", "typeof Date.now()"},
  {"bigint addition", "1n + 2n"},
  {"bigint compare", "2n > 1n"},
  {"symbol property", "let s=Symbol('x'); let o={[s]:3}; o[s]"},
  {"class static field", "class A { static x=3; static m(){return this.x} } A.m()"},
  {"private method", "class A { #m(){return 4} m(){return this.#m()} } new A().m()"},
  {"static super method",
   "class A { static m(){return 1} } class B extends A { static m(){return super.m()+2} } B.m()"},
  {"try finally return override", "function f(){ try { return 1 } finally { return 2 } } f()"},
  {"catch binding", "try { throw 5 } catch(e) { e+1 }"},
  {"for in keys", "let s=''; for (let k in {a:1,b:2}) s+=k; s.length"},
  {"for of destructuring", "let s=0; for (let [x] of [[1],[2]]) s+=x; s"},
  {"spread constructor", "function A(a,b){this.v=a+b}; new A(...[1,2]).v"},
  {"rest parameter", "function f(...xs){ return xs.length + xs[0] } f(3,4)"},
  {"array filter join", "[1,2,3,4].filter(function(x){return x%2===0}).join(',')"},
  {"array find", "[1,2,3].find(function(x){return x>1})"},
  {"array includes", "[1,2,3].includes(2)"},
  {"string replace", "'a-b'.replace('-', '+')"},
  {"string split length", "'a,b,c'.split(',').length"},
  {"number to fixed", "(1.25).toFixed(1)"},
  {"math max", "Math.max(1,5,3)"},
  {"object assign", "let o=Object.assign({a:1},{b:2}); o.b"},
  {"object define property", "let o={}; Object.defineProperty(o,'x',{value:4}); o.x"},
  {"property descriptor", "let o={x:1}; Object.getOwnPropertyDescriptor(o,'x').value"},
  {"set size", "let s=new Set([1,2,2]); s.size"},
  {"map size", "let m=new Map([['a',1],['b',2]]); m.size"},
  {"weakmap basic", "let k={}; let m=new WeakMap(); m.set(k,3); m.get(k)"},
  {"uint16 overflow", "let a=new Uint16Array(1); a[0]=65537; a[0]"},
  {"text encoder length", "new TextEncoder().encode('abc').length"},
  {"url pathname", "new URL('https://x.test/a?b=1').pathname"},
  {"regexp replace capture", "'abc'.replace(/(b)/, '[$1]')"},
  {"class getter setter",
   "class A { set x(v){this.v=v} get x(){return this.v} } let a=new A(); a.x=5; a.x"},
  {"static block", "class A { static { this.x=6 } } A.x"},
  {"private static field", "class A { static #x=7; static m(){return this.#x} } A.m()"},
  {"optional call missing", "let f=null; f?.() === undefined"},
  {"optional chain element", "let o={a:[3]}; o?.a?.[0]"},
  {"nested destructuring", "let {a:{b}}={a:{b:8}}; b"},
  {"rest object", "let {a,...r}={a:1,b:2}; r.b"},
  {"spread array", "let a=[1,...[2,3]]; a.length"},
  {"default param closure", "function f(x=3){return function(){return x}} f()()"},
  {"arrow this lexical", "let o={x:4,m(){let f=()=>this.x; return f()}}; o.m()"},
  {"eval local", "function f(){ var x=1; eval('x=2'); return x } f()"},
  {"direct eval expr", "eval('1+2')"},
  {"function bind", "function f(a,b){return a+b}; f.bind(null,2)(3)"},
  {"call apply", "function f(a,b){return a+b}; f.apply(null,[2,4])"}
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
