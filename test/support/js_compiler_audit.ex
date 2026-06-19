defmodule QuickBEAM.JS.CompilerAudit do
  @moduledoc false

  alias QuickBEAM.JS.Compiler, as: JSCompiler
  alias QuickBEAM.VM.Compiler, as: VMCompiler
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Heap.Arrays
  alias QuickBEAM.VM.Interpreter

  def cases do
    [
      {"literal integer", "1"},
      {"arithmetic precedence", "1 + 2 * 3"},
      {"large int32 literal", "2147483647"},
      {"local declaration", "let x = 1; x + 2"},
      {"if consequent", "let x = 0; if (1 < 2) x = 3; x"},
      {"if alternate", "let x = 0; if (1 > 2) x = 3; else x = 4; x"},
      {"while loop", "let x = 0; while (x < 3) { x = x + 1; } x"},
      {"function call", "function f(a){ return a + 1; } f(2)"},
      {"wide function closure index",
       Enum.map_join(0..260, ";", &"function f#{&1}(){return #{rem(&1, 10)}}") <> ";f260()"},
      {"function expression", "let f = function(a){ return a + 1; }; f(2)"},
      {"simple arrow function", "let f = x => x + 1; f(2)"},
      {"class static field and method",
       "class A { static x = 3; static m() { return this.x + 1; } } A.m()"},
      {"computed class method", "let k='m'; class A { [k](){ return 1; } } new A().m()"},
      {"computed static method", "let k='m'; class A { static [k](){ return 1; } } A.m()"},
      {"class expression",
       "function f(){ let o = { x: class { m(){ return 1; } } }; return 1 } 1"},
      {"array map arrow", "[1, 2, 3].map(x => x + 1).join(',')"},
      {"equality", "let x = 1; x === 1"},
      {"undefined", "undefined"},
      {"bitwise not", "~1"},
      {"left shift", "1 << 4"},
      {"signed right shift", "-8 >> 1"},
      {"unsigned right shift", "-1 >>> 0"},
      {"bitwise and assignment", "let x=7; x &= 3; x"},
      {"bitwise or assignment", "let x=4; x |= 3; x"},
      {"bitwise xor assignment", "let x=7; x ^= 3; x"},
      {"object is", "Object.is(-0, 0)"},
      {"math max", "Math.max(1, 2)"},
      {"in operator", "'x' in {x: 1}"},
      {"delete property", "let o={x:1}; delete o.x; o.x === undefined"},
      {"computed delete property", "let o={x:1}; delete o['x']; o.x === undefined"},
      {"delete var binding", "var x = 1; delete x"},
      {"assignment expression", "let x = 1; x = x + 2; x"},
      {"string constant", "'quick'"},
      {"float constant", "1.5"},
      {"unary negation", "let x = 2; -x"},
      {"logical not", "!false"},
      {"conditional expression", "let x = 1; x === 1 ? 2 : 3"},
      {"array length", "let a = [1, 2, 3]; a.length"},
      {"array index", "let a = [1, 2, 3]; a[1]"},
      {"object property", "let o = {x: 1, y: 2}; o.x + o.y"},
      {"object spread", "let a={x:1}; let b={...a, y:2}; b.y"},
      {"object proto literal", "let p={x:1}; let o={__proto__:p}; o.x"},
      {"object getter", "let o = { get x() { return 4; } }; o.x"},
      {"class getter", "class A { get x(){ return 4; } } new A().x"},
      {"logical member or-assign", "let o={x:0}; o.x ||= 2; o.x"},
      {"logical member and-assign", "let o={x:1}; o.x &&= 2; o.x"},
      {"logical member nullish-assign", "let o={x:null}; o.x ??= 2; o.x"},
      {"object destructuring assignment", "let target=[0]; ({a: target[0]} = {a:1}); target[0]"},
      {"computed destructuring assignment",
       "let target={}; let p='a'; ({[p]: target.x} = {a:1}); target.x"},
      {"object shorthand", "let x = 1; ({x}).x"},
      {"object destructuring", "let {x} = {x: 9}; x"},
      {"object destructuring multiple", "let {x, y} = {x: 2, y: 3}; x + y"},
      {"array destructuring", "let [a,,b] = [1,2,3]; b"},
      {"optional member null", "let o = null; o?.x === undefined"},
      {"optional member object", "let o = {x: 1}; o?.x"},
      {"computed object key", "let k = \"x\"; ({[k]: 2}).x"},
      {"computed numeric object key", "({[1]: 2})[1]"},
      {"object property assignment", "let o = {x: 1}; o.x = 2; o.x"},
      {"member assignment value", "let o={}; let y=(o.x=2); y+o.x"},
      {"computed assignment value", "let a=[0]; let y=(a[0]=2); y+a[0]"},
      {"generic call arity", "function f(a,b,c,d){ return a+b+c+d; } f(1,2,3,4)"},
      {"for loop", "let s=0; for(let i=0; i<4; i=i+1){ s=s+i; } s"},
      {"nested for loop",
       "let s = 0; for (let i = 0; i < 4; i++) { for (let j = 0; j < 3; j++) s += i + j; } s"},
      {"loop break", "let x=0; while (x < 5) { x=x+1; break; } x"},
      {"loop continue", "let x=0; let y=0; while (x < 3) { x=x+1; continue; y=9; } x+y"},
      {"do while loop", "let x=0; do { x=x+1; } while (x<3); x"},
      {"do while break", "let x=0; do { break; } while (true); x"},
      {"do while continue", "let x=0; do { x=x+1; continue; x=9; } while (x<3); x"},
      {"logical and", "let x=0; true && (x=1); x"},
      {"logical or", "let x=0; false || (x=1); x"},
      {"nullish null", "null ?? 3"},
      {"nullish value", "0 ?? 3"},
      {"sequence expression", "let x=0; (x=1, x+2)"},
      {"sequence declaration", "let x=0; let y=(x=1, x+2); y+x"},
      {"tagged template", "function tag(s){return s.raw[0]}; tag`x`"},
      {"tagged template member", "function tag(s){return s.raw[0]}; let a=[tag]; a[0]`x`"},
      {"template literal", "let x = 2; `${x + 1}`"},
      {"template literal parts", "`a${1}b${2}c`"},
      {"simple switch",
       "let x = 2; switch (x) { case 1: x = 10; break; case 2: x = 20; break; } x"},
      {"simple switch default",
       "let x = 0; switch (2) { case 1: x = 1; break; default: x = 3; } x"},
      {"for of array", "let s = 0; for (const x of [1, 2, 3]) s += x; s"},
      {"for of array destructuring", "let s=0; for (const [x] of [[1],[2]]) s += x; s"},
      {"for in static object", "let s = ''; for (const k in {a: 1, b: 2}) s += k; s.length"},
      {"for in object keys",
       "let o = {a: 1, b: 2}; let s = ''; for (let k in o) { s = s + k; } s.length"},
      {"simple throw catch", "try { throw 3; } catch (e) { e + 1; }"},
      {"simple try finally", "let x = 0; try { x = 1; } finally { x = x + 1; } x"},
      {"constructor call", "function C(){ this.x = 3; } let c = new C(); c.x"},
      {"simple class method", "class A { m() { return 1; } } new A().m()"},
      {"simple class constructor", "class A { constructor() { this.x = 1; } } new A().x"},
      {"simple class inheritance",
       "class A { m() { return 1; } } class B extends A { m() { return super.m() + 1; } } new B().m()"},
      {"regexp test", "/a+/.test('aa')"},
      {"post increment", "let x=1; x++; x"},
      {"pre increment", "let x=1; ++x"},
      {"post decrement", "let x=1; x--; x"},
      {"array element post update", "let a=[1]; a[0]++"},
      {"array element prefix update", "let a=[1]; ++a[0]"},
      {"member post update", "let o={x:1}; o.x++"},
      {"member prefix update", "let o={x:1}; ++o.x"},
      {"compound add", "let x=3; x += 4; x"},
      {"compound multiply", "let x=6; x *= 7; x"},
      {"compound array assignment", "let a=[1]; (a[0] += 2)"},
      {"compound member assignment", "let o={x:1}; o.x += 2"},
      {"exponent", "2 ** 3"},
      {"compound exponent", "let x=2; x **= 3; x"},
      {"logical assignment or", "let x = 0; x ||= 2; x"},
      {"logical assignment and", "let x = 1; x &&= 3; x"},
      {"logical assignment nullish", "let x = null; x ??= 4; x"},
      {"array write", "let a=[1]; a[0]=3; a[0]"},
      {"array elision length", "let a=[,1,,2]; a.length"},
      {"computed object write", "let o={x:1}; o[\"x\"]=2; o.x"},
      {"function if return", "function f(x){ if (x) return 1; return 2; } f(true)"},
      {"function loop return", "function f(){ while (true) { return 5; } } f()"},
      {"function for break", "function f(){ for(;;){ break; } return 1; } f()"},
      {"function arg4 read", "function f(a,b,c,d,e){return e;} f(1,2,3,4,5)"},
      {"function arg4 write", "function f(a,b,c,d,e){ e=6; return e; } f(1,2,3,4,5)"},
      {"function arg4 strict write",
       "function f(a,b,c,d,e){ 'use strict'; e=6; return e; } f(1,2,3,4,5)"},
      {"array spread call", "function f(a, b, c) { return a + b + c; } f(...[1, 2, 3])"},
      {"default parameter", "function f(x = 3) { return x; } f() + f(2)"},
      {"rest parameter", "function f(...xs) { return xs[0] + xs.length; } f(4, 5)"},
      {"destructured parameters", "function f({x}, [y]) { return x + y; } f({x: 1}, [2])"},
      {"function block var", "function f(){ if (true) { var x = 1; } return x; } f()"},
      {"function block let hidden",
       "function f(){ if (true) { let x = 1; } return typeof x; } f()"},
      {"closure captures parameter",
       "function make(x){ return function(y){ return x + y; }; } make(2)(3)"},
      {"closure captures local",
       "function make(){ let x = 2; return function(y){ return x + y; }; } make()(3)"},
      {"function declaration captures local",
       "function f(){ let a=1,b=2; function g(){ return b; } return g(); } f()"},
      {"function declaration captures args",
       "function f(a,b,c,d){ function g(){ return a+b+c+d; } return g(); } f(1,2,3,4)"},
      {"method call", "let o={f:function(){return 2}}; o.f()"},
      {"method this call", "let o={x:1,f:function(){return this.x}}; o.f()"},
      {"object method syntax", "let o={x:1,f(){return this.x}}; o.f()"},
      {"object method args", "let o={f(a,b){return a+b}}; o.f(2,3)"},
      {"computed method call", "let o={f:function(){return 3}}; o[\"f\"]()"},
      {"array method call", "let a=[function(){return 4}]; a[0]()"}
    ]
  end

  def run(cases \\ cases()) do
    Enum.map(cases, fn {name, source} -> run_case(name, source) end)
  end

  def summary(results) do
    frequencies = Enum.frequencies_by(results, & &1.status)

    %{
      cases: length(results),
      compiled: Map.get(frequencies, :pass, 0) + Map.get(frequencies, :mismatch, 0),
      unsupported: Map.get(frequencies, :unsupported, 0),
      mismatches: Map.get(frequencies, :mismatch, 0),
      failures: length(results) - Map.get(frequencies, :pass, 0)
    }
  end

  def run_case(name, source) do
    Task.async(fn -> do_run_case(name, source) end)
    |> Task.await(30_000)
  end

  defp do_run_case(name, source) do
    expected = native_eval(source)

    case safe_compile(source) do
      {:ok, bytecode} ->
        interpreter = run_interpreter(bytecode)
        compiler = run_compiler(bytecode)

        status = comparison_status(expected, interpreter, compiler)

        %{
          name: name,
          source: source,
          status: status,
          expected: expected,
          interpreter: interpreter,
          compiler: compiler
        }

      {:error, {:unsupported, _reason} = reason} ->
        %{name: name, source: source, status: :unsupported, expected: expected, reason: reason}

      {:error, reason} ->
        %{name: name, source: source, status: :error, expected: expected, reason: reason}
    end
  end

  defp comparison_status(expected, interpreter, compiler) do
    cond do
      expected == interpreter and expected == compiler ->
        :pass

      expected == {:error, {:js_error, "ReferenceError", "gc is not defined"}} and
          interpreter == compiler ->
        :pass

      true ->
        :mismatch
    end
  end

  defp safe_compile(source) do
    JSCompiler.compile(source)
  rescue
    exception ->
      {:error, {:compile_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:compile_throw, kind, reason}}
  end

  defp native_eval(source) do
    {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      normalize_result(QuickBEAM.eval(rt, source))
    after
      QuickBEAM.stop(rt)
    end
  end

  defp run_interpreter(bytecode) do
    Heap.reset()

    safe_result(:interpreter, fn ->
      normalize_result(Interpreter.eval(bytecode.value, [], %{gas: 1_000_000}, bytecode.atoms))
    end)
  end

  defp run_compiler(bytecode) do
    safe_result(:compiler, fn -> normalize_result(VMCompiler.invoke(bytecode.value, [])) end)
  end

  defp safe_result(stage, fun) do
    fun.()
  rescue
    exception -> {:error, {stage, :exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {stage, :throw, kind, reason}}
  end

  defp normalize_result({:ok, value}), do: {:ok, normalize(value)}
  defp normalize_result({:error, reason}), do: {:error, normalize(reason)}
  defp normalize_result(other), do: other

  defp normalize(value) when is_float(value) do
    if value == 0.0 and :erlang.float_to_binary(value) == "-0.00000000000000000000e+00" do
      -0.0
    else
      value
    end
  end

  defp normalize(:undefined), do: nil
  defp normalize(:nan), do: :NaN
  defp normalize(:neg_infinity), do: :"-Infinity"
  defp normalize(:infinity), do: :Infinity
  defp normalize({:js_throw, value}), do: {:js_throw, normalize(value)}
  defp normalize({:obj, ref}), do: normalize_heap_object(Heap.get_obj(ref))
  defp normalize({:closure, _captures, %QuickBEAM.VM.Function{}}), do: :function
  defp normalize({:builtin, name, callback}) when is_function(callback), do: {:builtin, name}
  defp normalize(%QuickBEAM.VM.Function{}), do: :function
  defp normalize(%QuickBEAM.JS.Error{} = error), do: {:js_error, error.name, error.message}
  defp normalize(value) when is_list(value), do: {:array, Enum.map(value, &normalize/1)}

  defp normalize(%struct{} = value) when is_atom(struct), do: {struct, inspect(value)}

  defp normalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {key, normalize(value)} end)
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> then(&{:object, &1})
  end

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
end
