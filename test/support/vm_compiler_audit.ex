defmodule QuickBEAM.VM.CompilerAudit do
  @moduledoc false

  alias QuickBEAM.VM.{BytecodeParser, Compiler, Heap, Interpreter}
  alias QuickBEAM.VM.Heap.Arrays

  @gas 1_000_000_000

  def cases do
    [
      {"literal integer", "1"},
      {"literal float", "1.5"},
      {"literal string", "'quick'"},
      {"literal boolean", "true"},
      {"literal null", "null"},
      {"undefined", "undefined"},
      {"addition", "1 + 2"},
      {"subtraction", "7 - 3"},
      {"multiplication", "6 * 7"},
      {"division", "8 / 2"},
      {"modulo", "7 % 3"},
      {"negative zero", "-0"},
      {"negative zero reciprocal", "1 / -0"},
      {"negative zero sign", "Object.is(-0, 0)"},
      {"unary plus string", "+'3'"},
      {"bitwise not", "~1"},
      {"left shift", "1 << 4"},
      {"signed right shift", "-8 >> 1"},
      {"unsigned right shift", "-1 >>> 0"},
      {"string concat", "'a' + 'b'"},
      {"mixed concat", "'a' + 1"},
      {"less than", "1 < 2"},
      {"greater than", "3 > 2"},
      {"strict equality", "1 === 1"},
      {"loose equality", "1 == '1'"},
      {"logical and", "true && 3"},
      {"logical or", "false || 4"},
      {"nullish coalescing", "null ?? 5"},
      {"conditional", "true ? 1 : 2"},
      {"var assignment", "var x = 1; x = x + 2; x"},
      {"let assignment", "let x = 1; x += 2; x"},
      {"const read", "const x = 4; x"},
      {"if branch", "let x = 0; if (true) x = 3; x"},
      {"while loop", "let s = 0; let i = 0; while (i < 5) { s += i; i++; } s"},
      {"break loop", "let x = 0; while (true) { x++; break; } x"},
      {"continue loop",
       "let s = 0; for (let i = 0; i < 5; i++) { if (i === 2) continue; s += i; } s"},
      {"function call", "function inc(x) { return x + 1; } inc(2)"},
      {"nested function",
       "function outer(x) { function inner(y) { return y + 1; } return inner(x); } outer(3)"},
      {"recursive function", "function f(n) { return n ? f(n - 1) + 1 : 0; } f(4)"},
      {"closure", "function make(x) { return function(y) { return x + y; }; } make(2)(3)"},
      {"array literal", "[1, 2, 3]"},
      {"array length", "let a = [1, 2, 3]; a.length"},
      {"array index", "let a = [1, 2, 3]; a[1]"},
      {"array sum",
       "let a = [1, 2, 3]; let s = 0; for (let i = 0; i < a.length; i++) s += a[i]; s"},
      {"object literal", "({x: 7, y: 8})"},
      {"object property", "let o = {x: 7}; o.x"},
      {"computed property", "let o = {x: 7}; o['x']"},
      {"method call", "let o = {x: 2, f() { return this.x + 1; }}; o.f()"},
      {"destructuring", "let {x} = {x: 9}; x"},
      {"delete property", "let o = {x: 1}; delete o.x; o.x === undefined"},
      {"in operator", "'x' in {x: 1}"},
      {"optional chaining", "let o = null; o?.x === undefined"},
      {"for of array", "let s = 0; for (const x of [1, 2, 3]) s += x; s"},
      {"for in object", "let s = ''; for (const k in {a: 1, b: 2}) s += k; s.length"},
      {"template literal", "let x = 2; `${x + 1}`"},
      {"try catch", "try { throw 3; } catch (e) { e + 1; }"},
      {"switch", "let x = 2; switch (x) { case 1: x = 10; break; case 2: x = 20; break; } x"},
      {"regexp test", "/a+/.test('aa')"},
      {"class method", "class A { m() { return 1; } } new A().m()"},
      {"class instance", "class A { constructor() { this.x = 1; } } new A()"},
      {"class inheritance",
       "class A { m() { return 1; } } class B extends A { m() { return super.m() + 1; } } new B().m()"}
    ]
  end

  def corpus_cases do
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
      ">>>",
      "**",
      "==",
      "!="
    ]

    values = ["-3", "-1", "0", "1", "2", "5", "'2'", "true", "false", "null"]

    binary_cases =
      for op <- binary_ops,
          left <- values,
          right <- values,
          not (op in ["/", "%"] and right == "0"),
          not (op == "**" and String.starts_with?(left, "-")) do
        {"binary #{left} #{op} #{right}", "#{left} #{op} #{right}"}
      end

    many_function_declarations =
      0..299
      |> Enum.map_join(";", fn idx -> "function f#{idx}(){return #{idx}}" end)
      |> then(&(&1 <> "; f299()"))

    long_assignment_sequence = Enum.map_join(1..500, ",", fn _ -> "x=x+1" end)
    long_if_body = Enum.map_join(1..300, ";", fn _ -> "x=x+1" end)
    long_else_body = Enum.map_join(1..1000, ";", fn _ -> "x=x+1" end)
    very_long_else_body = Enum.map_join(1..2500, ";", fn _ -> "x=x+1" end)

    custom_iterator =
      "let it={ [Symbol.iterator](){ return { i:0, next(){ return this.i++ < 2 ? {value:this.i, done:false} : {done:true}; } } } };"

    many_string_globals = Enum.map_join(0..299, ";", fn idx -> "let s#{idx}='#{idx}'" end)
    many_var_locals = Enum.map_join(0..260, ";", fn idx -> "var a#{idx}=#{rem(idx, 10)}" end)

    high_value_cases = [
      {"call zero args", "function f(){ return 3; } f()"},
      {"call two args", "function f(a, b){ return a * 10 + b; } f(2, 3)"},
      {"call three args", "function f(a, b, c){ return a + b * c; } f(2, 3, 4)"},
      {"call four args", "function f(a, b, c, d){ return a + b + c + d; } f(1, 2, 3, 4)"},
      {"argument aliases",
       "function f(a, b, c, d){ a = 4; b = b + 1; return a + b + c + d; } f(1, 2, 3, 4)"},
      {"return arg1", "function f(a,b){return b;} f(1,2)"},
      {"return arg2", "function f(a,b,c){return c;} f(1,2,3)"},
      {"return arg3", "function f(a,b,c,d){return d;} f(1,2,3,4)"},
      {"return arg4", "function f(a,b,c,d,e){return e;} f(1,2,3,4,5)"},
      {"set arg1", "function f(a,b){ b=5; return b;} f(1,2)"},
      {"set arg2", "function f(a,b,c){ c=5; return c;} f(1,2,3)"},
      {"set arg3", "function f(a,b,c,d){ d=5; return d;} f(1,2,3,4)"},
      {"set arg4 strict", "function f(a,b,c,d,e){ 'use strict'; e=6; return e; } f(1,2,3,4,5)"},
      {"many locals",
       "let a0=0,a1=1,a2=2,a3=3,a4=4,a5=5,a6=6,a7=7,a8=8; a0+a1+a2+a3+a4+a5+a6+a7+a8"},
      {"many function locals",
       "function f(){ let a0=0,a1=1,a2=2,a3=3,a4=4,a5=5,a6=6,a7=7,a8=8,a9=9; return a9; } f()"},
      {"set local2", "function f(){ var a0=0; var a1=1; var a2=2; a2=7; return a2 } f()"},
      {"set local8",
       "function f(){ var a0=0; var a1=1; var a2=2; var a3=3; var a4=4; a4=7; return a4 } f()"},
      {"generic local read", "function f(){ #{many_var_locals}; eval(''); return a260 } f()"},
      {"generic local write", "function f(){ #{many_var_locals}; a260=7; return a260 } f()"},
      {"var local add", "function f(){ var x=1,y=2; x += y; return x } f()"},
      {"typeof number", "typeof 1"},
      {"typeof function", "typeof function(){}"},
      {"typeof missing", "typeof missing === 'undefined'"},
      {"typeof function condition", "typeof function(){} === 'function'"},
      {"logical not", "!0"},
      {"is null branch", "let x = null; x === null ? 1 : 2"},
      {"instanceof class", "class A {} let a = new A(); a instanceof A"},
      {"power operator", "2 ** 5"},
      {"bitwise and var", "let x = 7; x &= 3; x"},
      {"bitwise or var", "let x = 4; x |= 3; x"},
      {"bitwise xor var", "let x = 7; x ^= 3; x"},
      {"lte branch", "let x = 2; x <= 2 ? 1 : 0"},
      {"gte branch", "let x = 2; x >= 3 ? 1 : 0"},
      {"strict neq", "1 !== '1'"},
      {"loose neq", "1 != '1'"},
      {"nested loops",
       "let s = 0; for (let i = 0; i < 4; i++) { for (let j = 0; j < 3; j++) s += i + j; } s"},
      {"switch default",
       "let x = 3; let y = 0; switch (x) { case 1: y = 1; break; default: y = 9; } y"},
      {"wide if false", "let x=0; if (x===0) { #{long_if_body}; } x"},
      {"wide logical or", "let x=1; x || (#{long_assignment_sequence}); x"},
      {"wide goto", "let x=0; if (x===0) { x=1; } else { #{long_else_body}; } x"},
      {"generic goto", "let x=0; if (x===0) { x=1; } else { #{very_long_else_body}; } x"},
      {"try finally", "let x = 1; try { x = 2; } finally { x = x + 3; } x"},
      {"catch rethrow avoided", "let x = 0; try { throw 5; } catch (e) { x = e; } x"},
      {"object mutation", "let o = {}; o.x = 1; o.y = o.x + 2; o"},
      {"array mutation", "let a = []; a[0] = 1; a[2] = 3; a"},
      {"array element call", "let a=[function(){return 3}]; a[0]()"},
      {"array element increment", "let a=[1]; a[0]++"},
      {"array elision length", "let a=[,1,,2]; a.length"},
      {"method this update",
       "let o = {x: 1, inc() { this.x++; return this.x; }}; o.inc() + o.inc()"},
      {"closure mutation",
       "function make(){ let x = 0; return function(){ x++; return x; }; } let f = make(); f() + f()"},
      {"capture second local",
       "function f(){ let a=1,b=2; function g(){ return b; } return g(); } f()"},
      {"capture third local",
       "function f(){ let a=1,b=2,c=3; function g(){ return c; } return g(); } f()"},
      {"capture fourth local",
       "function f(){ let a=1,b=2,c=3,d=4; function g(){ return d; } return g(); } f()"},
      {"capture arguments",
       "function f(a,b,c,d){ function g(){ return a+b+c+d; } return g(); } f(1,2,3,4)"},
      {"set captured arg1",
       "function f(a,b){ function g(){ a; b=b+1; return b; } return g(); } f(1,2)"},
      {"set captured arg2",
       "function f(a,b,c){ function g(){ a; b; c=c+1; return c; } return g(); } f(1,2,3)"},
      {"set captured arg3",
       "function f(a,b,c,d){ function g(){ a; b; c; d=d+1; return d; } return g(); } f(1,2,3,4)"},
      {"set captured arg4",
       "function f(a,b,c,d,e){ function g(){ a; b; c; d; e=e+1; return e; } return g(); } f(1,2,3,4,5)"},
      {"put captured arg0",
       "function f(a){ function g(){ a = a + 1; return 0; } return g(); } f(1)"},
      {"put captured arg1",
       "function f(a,b){ function g(){ a; b = b + 1; return 0; } return g(); } f(1,2)"},
      {"put captured arg2",
       "function f(a,b,c){ function g(){ a; b; c = c + 1; return 0; } return g(); } f(1,2,3)"},
      {"put captured arg3",
       "function f(a,b,c,d){ function g(){ a; b; c; d = d + 1; return 0; } return g(); } f(1,2,3,4)"},
      {"put captured arg4",
       "function f(a,b,c,d,e){ function g(){ a; b; c; d; e = e + 1; return 0; } return g(); } f(1,2,3,4,5)"},
      {"constructor fields", "function A(x) { this.x = x; } let a = new A(4); a.x"},
      {"class static", "class A { static x = 3; static m() { return this.x + 1; } } A.m()"},
      {"spread call", "function f(a, b, c) { return a + b + c; } f(...[1, 2, 3])"},
      {"rest args", "function f(...xs) { return xs[0] + xs.length; } f(4, 5)"},
      {"default param", "function f(x = 3) { return x; } f() + f(2)"},
      {"destructured param", "function f({x}, [y]) { return x + y; } f({x: 1}, [2])"},
      {"array destructuring", "let [a,,b] = [1,2,3]; b"},
      {"object destructuring", "let {x: y} = {x: 3}; y"},
      {"object pattern array target", "let target=[0]; ({a: target[0]} = {a:1}); target[0]"},
      {"object pattern computed field target",
       "let target={}; let p='a'; ({[p]: target.x} = {a:1}); target.x"},
      {"object pattern computed array target",
       "let target=[0]; let p='a'; ({[p]: target[0]} = {a:1}); target[0]"},
      {"object pattern super target",
       "class A{set x(v){this.y=v}} class B extends A{m(){ ({a: super.x} = {a:1}); return this.y }} new B().m()"},
      {"object pattern computed super target",
       "class A{set x(v){this.y=v}} class B extends A{m(){ let p='a'; ({[p]: super.x} = {a:1}); return this.y }} new B().m()"},
      {"for of destructuring", "let s=0; for (const [x] of [[1],[2]]) s += x; s"},
      {"custom iterator loop", custom_iterator <> "let s=0; for (let x of it) s+=x; s"},
      {"computed object key", "let k = 'x'; let o = {[k]: 5}; o.x"},
      {"computed function name", "let k='x'; let o = { [k]: function(){} }; o.x.name"},
      {"template expression", "let x = 4; `a${x + 1}`"},
      {"tagged array element",
       "function tag(strings){return strings.raw[0]}; let a=[tag]; a[0]`x`"},
      {"wide tagged template constant",
       many_string_globals <> "; function tag(strings){return strings.raw[0]}; tag`x`"},
      {"regexp replace", "'aa'.replace(/a/g, 'b')"},
      {"array map", "[1, 2, 3].map(x => x + 1).join(',')"},
      {"optional call", "let o = { f() { return 7; } }; o.f?.()"},
      {"nullish assignment", "let x = null; x ??= 4; x"},
      {"logical field assignment", "let o={x:0}; o.x ||= 2; o.x"},
      {"pre decrement", "let x = 3; --x"},
      {"post decrement", "let x = 3; x--"},
      {"delete var", "var x = 1; delete x"},
      {"bigint addition", "1n + 2n"},
      {"int16 literal", "128"},
      {"large int32 literal", "2147483647"},
      {"many function declarations", many_function_declarations},
      {"private field get", "class A { #x = 1; m(){ return this.#x; } } new A().m()"},
      {"private field set", "class A { #x; m(){ this.#x = 4; return this.#x; } } new A().m()"},
      {"private method", "class A { #m(){ return 4; } m(){ return this.#m(); } } new A().m()"},
      {"private getter", "class A { get #x(){ return 4; } m(){ return this.#x; } } new A().m()"},
      {"private in", "class A { #x; static has(o){ return #x in o; } } A.has(new A())"},
      {"super getter",
       "class A { get x(){ return 4; } } class B extends A { m(){ return super.x; } } new B().m()"},
      {"super setter",
       "class A { set x(v){ this.y=v } } class B extends A { m(){ super.x = 3; return this.y; } } new B().m()"},
      {"super compound assignment",
       "class A { get x(){return 1} set x(v){this.y=v} } class B extends A { m(){ super.x += 2; return this.y } } new B().m()"},
      {"super post increment return",
       "class A { get x(){return 1} set x(v){this.y=v} } class B extends A { m(){ return super.x++ } } new B().m()"},
      {"computed class method", "let k='m'; class A { [k](){ return 1; } } new A().m()"},
      {"computed static method", "let k='m'; class A { static [k](){ return 1; } } A.m()"},
      {"unused computed class value",
       "function f(){ let k='x'; let o = { [k]: class {} }; return 1 } 1"},
      {"object proto literal", "let p={x:1}; let o={__proto__:p}; o.x"},
      {"function expression name", "let f = function(){}; f.name"},
      {"named class expression", "let C = class {}; C.name"},
      {"eval expression", "eval('1+2')"},
      {"eval spread", "eval(...['1+2'])"},
      {"direct eval arguments", "function f(){ return eval('arguments[0]') } f(7)"},
      {"unused async function", "async function f(){ await 1; return 2; } 1"},
      {"unused generator function", "function* g(){ yield 1; return 2; } 1"},
      {"unused yield star", "function* g(){ yield* [1,2]; } 1"},
      {"unused async generator", "async function* g(){ yield 1; await 2; } 1"},
      {"unused async yield star", "async function* g(){ yield* [1,2]; } 1"},
      {"unused dynamic import", "function f(){ return import('x') } 1"},
      {"unused for await", "async function f(){ for await (const x of [1]) {} return 1 } 1"},
      {"unused with method call", "function f(){ let o={m(){return 1}}; with(o){ m() } } 1"},
      {"unused with local assignment", "function f(){ let x=1; let o={}; with(o){ x=2 } } 1"},
      {"unused with argument assignment", "function f(a){ let o={}; with(o){ a=2 } } 1"},
      {"unused with global assignment", "function f(){ let o={}; with(o){ x=2 } } 1"},
      {"unused with captured assignment",
       "function f(){ let x=1; function g(){ let o={}; with(o){ x=2 } } } 1"},
      {"unused with captured update",
       "function f(){ let x=1; function g(){ let o={}; with(o){ x++ } } } 1"},
      {"eval var increment", "function f(){ var x=1; eval(''); x++; return x } f()"},
      {"eval var decrement", "function f(){ var x=1; eval(''); x--; return x } f()"},
      {"eval captured var assignment",
       "function f(){ var x=1; function g(){ eval(''); x=2; return x }; return g() } f()"},
      {"with delete", "let o={x:1}; with(o){ delete x; } 'x' in o"},
      {"derived constructor return object",
       "class A{}; class B extends A { constructor(){ super(); return {x:1}; } } new B().x"},
      {"unused derived super arrow",
       "class A{}; class B extends A { constructor(){ let f=()=>super(); f(); } } 1"},
      {"arguments write", "function f(){ arguments[0] = 3; return arguments[0]; } f(1)"},
      {"arguments alias put arg2",
       "function f(a,b,c){ arguments; c=2; return arguments[2] } f(1,3,4)"},
      {"arguments alias put arg3",
       "function f(a,b,c,d){ arguments; d=2; return arguments[3] } f(1,3,4,5)"},
      {"arguments alias put arg4",
       "function f(a,b,c,d,e){ arguments; e=2; return arguments[4] } f(1,3,4,5,6)"},
      {"object spread", "let a={x:1}; let b={...a, y:2}; b.y"},
      {"compound array assignment", "let a=[1]; (a[0] += 2)"},
      {"computed method name", "let f = {[('x')](){return 1}}.x; f.name"},
      {"try finally return", "function f(){ try { return 1; } finally { return 2; } } f()"}
    ]

    cases() ++ binary_cases ++ high_value_cases
  end

  def run_all do
    Enum.map(cases(), fn {name, source} -> run_case(name, source) end)
  end

  def run_auto_case(name, source) do
    nif = eval_result(source, :nif)
    auto = eval_result(source, :auto)

    %{
      name: name,
      source: source,
      status: classify(nif, auto),
      interpreter: nif,
      compiler: auto,
      fallback_reason: nil
    }
  end

  def run_case(name, source) do
    case compile_source(source) do
      {:ok, parsed} ->
        fun = parsed.value
        compiler = compiler_result(fun, parsed.atoms)
        interpreter = interpreter_result(fun, parsed.atoms)

        status = classify(interpreter, compiler)

        %{
          name: name,
          source: source,
          status: status,
          interpreter: interpreter,
          compiler: compiler,
          fallback_reason: fallback_reason(compiler)
        }

      {:error, reason} ->
        %{
          name: name,
          source: source,
          status: :compile_input_error,
          interpreter: {:error, reason},
          compiler: {:error, reason},
          fallback_reason: nil
        }
    end
  end

  def summary(results) do
    grouped = Enum.frequencies_by(results, & &1.status)

    %{
      cases: length(results),
      compiled: Map.get(grouped, :compiled, 0),
      fallbacks: Map.get(grouped, :fallback, 0),
      crashes: Map.get(grouped, :crash, 0),
      mismatches: Map.get(grouped, :mismatch, 0),
      input_errors: Map.get(grouped, :compile_input_error, 0),
      fallback_reasons: fallback_reasons(results)
    }
  end

  defp compile_source(source) do
    Heap.reset()

    {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      case QuickBEAM.compile(rt, source) do
        {:ok, bytecode} -> BytecodeParser.decode(bytecode)
        error -> error
      end
    after
      QuickBEAM.stop(rt)
    end
  end

  defp eval_result(source, mode) do
    isolated(fn ->
      {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        opts = if mode == :auto, do: [mode: :auto], else: []

        case QuickBEAM.eval(rt, source, opts) do
          {:ok, value} -> {:ok, normalize(value)}
          {:error, reason} -> {:error, normalize(reason)}
        end
      after
        QuickBEAM.stop(rt)
      end
    end)
  end

  defp interpreter_result(fun, atoms) do
    isolated(fn ->
      case Interpreter.eval(fun, [], %{gas: @gas}, atoms) do
        {:ok, value} -> {:ok, normalize(value)}
        {:error, reason} -> {:error, normalize(reason)}
      end
    end)
  end

  defp compiler_result(fun, atoms) do
    isolated(fn ->
      cache_function_atoms(fun, atoms)

      case Compiler.compile(fun) do
        {:ok, _compiled} ->
          case Compiler.invoke(fun, []) do
            {:ok, value} -> {:ok, normalize(value)}
            :error -> {:fallback, :invoke_returned_error}
            {:error, reason} -> {:error, normalize(reason)}
          end

        {:error, reason} ->
          {:fallback, reason}
      end
    end)
  end

  defp isolated(fun) do
    Task.async(fn ->
      Heap.reset()
      {:ok, rt} = QuickBEAM.start(apis: false)
      initialize_runtime(rt)

      try do
        fun.()
      rescue
        exception -> {:crash, Exception.message(exception)}
      catch
        kind, reason -> {:crash, {kind, reason}}
      after
        QuickBEAM.stop(rt)
      end
    end)
    |> Task.await(30_000)
  end

  defp initialize_runtime(rt) do
    QuickBEAM.compile(rt, "0")
    :ok
  end

  defp cache_function_atoms(%QuickBEAM.VM.Function{} = fun, atoms) do
    Heap.put_fn_atoms(fun, atoms)

    Enum.each(fun.constants, fn
      %QuickBEAM.VM.Function{} = inner -> cache_function_atoms(inner, atoms)
      _ -> :ok
    end)
  end

  defp classify({:ok, expected}, {:ok, actual}) do
    if equivalent?(expected, actual), do: :compiled, else: :mismatch
  end

  defp classify({:crash, _}, {:crash, _}), do: :compiled
  defp classify(_interpreter, {:fallback, _reason}), do: :fallback
  defp classify(_interpreter, {:crash, _reason}), do: :crash

  defp classify(interpreter, compiler),
    do: if(interpreter == compiler, do: :compiled, else: :mismatch)

  defp equivalent?(:nan, :nan), do: true
  defp equivalent?(a, b), do: a === b

  defp normalize(value) when is_float(value) do
    if value == 0.0 and :erlang.float_to_binary(value) == "-0.00000000000000000000e+00" do
      -0.0
    else
      value
    end
  end

  defp normalize({:js_throw, value}), do: {:js_throw, normalize(value)}
  defp normalize({:obj, ref}), do: normalize_heap_object(Heap.get_obj(ref))
  defp normalize({:closure, _captures, %QuickBEAM.VM.Function{}}), do: :function
  defp normalize({:builtin, name, callback}) when is_function(callback), do: {:builtin, name}
  defp normalize(%QuickBEAM.VM.Function{}), do: :function
  defp normalize(value), do: value

  defp normalize_heap_object({:qb_arr, _} = array),
    do: {:array, Enum.map(Arrays.to_list(array), &normalize/1)}

  defp normalize_heap_object(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} -> internal_key?(key) end)
    |> Enum.map(fn {key, value} -> {key, normalize(value)} end)
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> then(&{:object, &1})
  end

  defp normalize_heap_object(list) when is_list(list), do: {:array, Enum.map(list, &normalize/1)}
  defp normalize_heap_object(other), do: {:object, inspect(other)}

  defp internal_key?(key) when is_atom(key), do: true
  defp internal_key?("__proto__"), do: true
  defp internal_key?(_key), do: false

  defp fallback_reason({:fallback, reason}), do: inspect(reason)
  defp fallback_reason(_result), do: nil

  defp fallback_reasons(results) do
    results
    |> Enum.filter(&(&1.status == :fallback))
    |> Enum.frequencies_by(& &1.fallback_reason)
  end
end
