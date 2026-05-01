defmodule QuickBEAM.VM.CompilerTest do
  use ExUnit.Case, async: true

  import QuickBEAM.VM.Heap.Keys, only: [proto: 0]

  alias QuickBEAM.VM.{Bytecode, Compiler, Heap, Interpreter}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers
  alias QuickBEAM.VM.ObjectModel.Get

  setup do
    Heap.reset()
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  defp compile_and_decode(rt, code) do
    {:ok, bc} = QuickBEAM.compile(rt, code)
    {:ok, parsed} = Bytecode.decode(bc)
    cache_function_atoms(parsed.value, parsed.atoms)
    parsed
  end

  defp cache_function_atoms(%Bytecode.Function{} = fun, atoms) do
    Heap.put_fn_atoms(fun, atoms)

    Enum.each(fun.constants, fn
      %Bytecode.Function{} = inner -> cache_function_atoms(inner, atoms)
      _ -> :ok
    end)
  end

  defp user_function(parsed) do
    case for %Bytecode.Function{} = fun <- parsed.value.constants, do: fun do
      [fun | _] -> fun
      [] -> parsed.value
    end
  end

  defp compiled_key(%Bytecode.Function{} = fun) do
    atoms = Heap.get_fn_atoms(fun, Heap.get_atoms())
    {fun.byte_code, fun.arg_count, :erlang.phash2(fun), :erlang.phash2(atoms)}
  end

  defp beam_extfuncs({:beam_file, _module, _exports, _attributes, _compile_info, code}) do
    for {:function, _name, _arity, _label, instructions} <- code,
        {op, _argc, {:extfunc, mod, fun, arity}} <- instructions,
        op in [:call_ext, :call_ext_last, :call_ext_only] do
      {mod, fun, arity}
    end
  end

  defp beam_function_instructions(
         {:beam_file, _module, _exports, _attributes, _compile_info, code},
         name
       ) do
    Enum.find_value(code, fn
      {:function, ^name, _arity, _label, instructions} -> instructions
      _ -> nil
    end)
  end

  describe "compile/1" do
    test "compiles a straight-line arithmetic function", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){return a+b})") |> user_function()

      assert {:ok, {_mod, :run_ctx}} = Compiler.compile(fun)
      assert {:ok, 7} = Compiler.invoke(fun, [3, 4])
    end

    test "compiles locals and reassignment in straight-line code", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a){let x=1; x=x+a; return x})") |> user_function()

      assert {:ok, 6} = Compiler.invoke(fun, [5])
    end

    test "compiles top-level var declarations and writes", %{rt: rt} do
      root = compile_and_decode(rt, "var x = 1; x = x + 2; x").value

      assert {:ok, {_mod, :run_ctx}} = Compiler.compile(root)
      assert {:ok, 3} = Compiler.invoke(root, [])
    end

    test "compiles top-level function declarations", %{rt: rt} do
      root = compile_and_decode(rt, "function inc(x){ return x + 1 } inc(2)").value

      assert {:ok, {_mod, :run_ctx}} = Compiler.compile(root)
      assert {:ok, 3} = Compiler.invoke(root, [])
    end

    test "compiled disasm skips TDZ helper after initialized unknown locals", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(f){ const value = f(); return value + value })")
        |> user_function()

      assert {:ok, beam_file} = Compiler.disasm(fun)
      refute {RuntimeHelpers, :ensure_initialized_local!, 1} in beam_extfuncs(beam_file)

      callback = {:builtin, "one", fn [], _ -> 1 end}
      assert {:ok, 2} = Compiler.invoke(fun, [callback])
    end

    test "compiles conditional branches", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){if(x>0)return 1;else return 2})") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [3])
      assert {:ok, 2} = Compiler.invoke(fun, [-1])
    end

    test "compiles simple while loops", %{rt: rt} do
      code = "(function(n){let s=0; let i=0; while(i<n){ s=s+i; i=i+1;} return s})"
      fun = compile_and_decode(rt, code) |> user_function()

      assert {:ok, beam_file} = Compiler.disasm(fun)
      refute {QuickBEAM.VM.Interpreter.Values, :truthy?, 1} in beam_extfuncs(beam_file)

      block = beam_function_instructions(beam_file, :block_6)

      assert Enum.any?(block, fn
               {:test, :is_number, _, _} -> true
               _ -> false
             end)

      assert Enum.any?(block, fn
               {:bif, :<, _, _, _} -> true
               _ -> false
             end)

      assert {:ok, 10} = Compiler.invoke(fun, [5])
    end

    test "compiles loops over array length and array indexing", %{rt: rt} do
      code =
        "(function(arr){let s=0; let i=0; while(i<arr.length){ s=s+arr[i]; i=i+1;} return s})"

      fun = compile_and_decode(rt, code) |> user_function()

      assert {:ok, 10} = Compiler.invoke(fun, [Heap.wrap([1, 2, 3, 4])])
    end

    test "compiles object destructuring", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(obj){ const {x} = obj; return x })") |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles regexp literals", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(){ return /a+/.test('aa') })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "compiles object field access", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(obj){return obj.x})") |> user_function()

      assert {:ok, beam_file} = Compiler.disasm(fun)
      block = beam_function_instructions(beam_file, :block_0)

      assert Enum.any?(block, fn
               {:call, 2, {_, :op_get_field, 2}} -> true
               {:call_only, 2, {_, :op_get_field, 2}} -> true
               {:call_last, 2, {_, :op_get_field, 2}, _} -> true
               _ -> false
             end)

      assert {:ok, 7} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles object creation plus field writes", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(v){ let o={}; o.x=v; return o.x })") |> user_function()

      assert {:ok, 9} = Compiler.invoke(fun, [9])
    end

    test "compiles object literals", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(v){ return {x:v} })") |> user_function()

      assert {:ok, beam_file} = Compiler.disasm(fun)
      block = beam_function_instructions(beam_file, :block_0)

      assert Enum.any?(block, fn
               {:call_ext, 1, {:extfunc, QuickBEAM.VM.Heap, :wrap, 1}} -> true
               {:call_ext_last, 1, {:extfunc, QuickBEAM.VM.Heap, :wrap, 1}, _} -> true
               {:call_ext_only, 1, {:extfunc, QuickBEAM.VM.Heap, :wrap, 1}} -> true
               {:call_ext, 2, {:extfunc, QuickBEAM.VM.Heap, :wrap_keyed, 2}} -> true
               {:call_ext_last, 2, {:extfunc, QuickBEAM.VM.Heap, :wrap_keyed, 2}, _} -> true
               {:call_ext_only, 2, {:extfunc, QuickBEAM.VM.Heap, :wrap_keyed, 2}} -> true
               _ -> false
             end)

      assert {:ok, {:obj, ref}} = Compiler.invoke(fun, [5])
      assert %{"x" => 5} = Heap.get_obj(ref)
    end

    test "enumerates numeric object literal keys", %{rt: rt} do
      keys = compile_and_decode(rt, "Object.keys({2:1,1:1,a:1}).join(',')").value
      values = compile_and_decode(rt, "Object.values({2:'b',1:'a',z:'c'}).join(',')").value

      entries =
        compile_and_decode(
          rt,
          "Object.entries({2:'b',1:'a',z:'c'}).map(e=>e[0]+e[1]).join(',')"
        ).value

      assert {:ok, "1,2,a"} = Compiler.invoke(keys, [])
      assert {:ok, "a,b,c"} = Compiler.invoke(values, [])
      assert {:ok, "1a,2b,zc"} = Compiler.invoke(entries, [])
    end

    test "reads default Object prototype methods", %{rt: rt} do
      has_own = compile_and_decode(rt, "({x:1}).hasOwnProperty('x')").value
      has_own_false = compile_and_decode(rt, "({}).hasOwnProperty('x')").value
      to_string = compile_and_decode(rt, "({}).toString()").value
      value_of = compile_and_decode(rt, "let o={x:1}; o.valueOf()===o").value
      enumerable = compile_and_decode(rt, "({x:1}).propertyIsEnumerable('x')").value
      is_prototype = compile_and_decode(rt, "({}).isPrototypeOf({})").value

      assert {:ok, true} = Compiler.invoke(has_own, [])
      assert {:ok, false} = Compiler.invoke(has_own_false, [])
      assert {:ok, "[object Object]"} = Compiler.invoke(to_string, [])
      assert {:ok, true} = Compiler.invoke(value_of, [])
      assert {:ok, true} = Compiler.invoke(enumerable, [])
      assert {:ok, false} = Compiler.invoke(is_prototype, [])
    end

    test "compiles typed array includes", %{rt: rt} do
      hit = compile_and_decode(rt, "new Uint8Array([1,2,3]).includes(2)").value
      miss = compile_and_decode(rt, "new Uint8Array([1,2,3]).includes(4)").value

      assert {:ok, true} = Compiler.invoke(hit, [])
      assert {:ok, false} = Compiler.invoke(miss, [])
    end

    test "compiles Reflect.construct helpers", %{rt: rt} do
      simple = compile_and_decode(rt, "function C(x){this.x=x}; Reflect.construct(C,[3]).x").value

      new_target =
        compile_and_decode(
          rt,
          "function C(){this.v=new.target===D}; function D(){}; Reflect.construct(C,[],D).v"
        ).value

      prototype =
        compile_and_decode(
          rt,
          "function C(){}; function D(){}; D.prototype={y:4}; Reflect.construct(C,[],D).y"
        ).value

      assert {:ok, 3} = Compiler.invoke(simple, [])
      assert {:ok, true} = Compiler.invoke(new_target, [])
      assert {:ok, 4} = Compiler.invoke(prototype, [])
    end

    test "compiles Proxy ownKeys traps", %{rt: rt} do
      trap_length =
        compile_and_decode(
          rt,
          "let p=new Proxy({a:1},{ownKeys(){return ['x','y']}}); Reflect.ownKeys(p).length"
        ).value

      default_keys =
        compile_and_decode(rt, "let p=new Proxy({a:1,b:2},{}); Reflect.ownKeys(p).length").value

      symbol_key =
        compile_and_decode(
          rt,
          "let s=Symbol('s'); let p=new Proxy({},{ownKeys(){return [s]}}); Reflect.ownKeys(p)[0]===s"
        ).value

      assert {:ok, 2} = Compiler.invoke(trap_length, [])
      assert {:ok, 2} = Compiler.invoke(default_keys, [])
      assert {:ok, true} = Compiler.invoke(symbol_key, [])
    end

    test "compiles Reflect.ownKeys without internal object metadata", %{rt: rt} do
      plain = compile_and_decode(rt, "let o={a:1,b:2}; Reflect.ownKeys(o).length").value

      symbol =
        compile_and_decode(
          rt,
          "let s=Symbol('s'); let o={a:1}; o[s]=2; Reflect.ownKeys(o).length"
        ).value

      numeric =
        compile_and_decode(rt, "let o={}; o[2]='b'; o[1]='a'; o.x='x'; Reflect.ownKeys(o).length").value

      assert {:ok, 2} = Compiler.invoke(plain, [])
      assert {:ok, 2} = Compiler.invoke(symbol, [])
      assert {:ok, 3} = Compiler.invoke(numeric, [])
    end

    test "compiles Reflect read and apply helpers", %{rt: rt} do
      reflect_apply =
        compile_and_decode(rt, "Reflect.apply(function(x){return x+1}, null, [2])").value

      reflect_get = compile_and_decode(rt, "Reflect.get({x:1}, 'x')").value
      reflect_set = compile_and_decode(rt, "let o={}; Reflect.set(o,'x',2); o.x").value
      reflect_has = compile_and_decode(rt, "Reflect.has({x:1}, 'x')").value

      assert {:ok, 3} = Compiler.invoke(reflect_apply, [])
      assert {:ok, 1} = Compiler.invoke(reflect_get, [])
      assert {:ok, 2} = Compiler.invoke(reflect_set, [])
      assert {:ok, true} = Compiler.invoke(reflect_has, [])
    end

    test "compiles Reflect property mutation helpers", %{rt: rt} do
      delete_property =
        compile_and_decode(rt, "let o={x:1}; Reflect.deleteProperty(o,'x'); o.x===undefined").value

      define_property =
        compile_and_decode(
          rt,
          "let o={}; Reflect.defineProperty(o,'x',{value:2, enumerable:true}); o.x"
        ).value

      non_enumerable =
        compile_and_decode(
          rt,
          "let o={}; Reflect.defineProperty(o,'x',{value:2, enumerable:false}); Object.keys(o).length"
        ).value

      assert {:ok, true} = Compiler.invoke(delete_property, [])
      assert {:ok, 2} = Compiler.invoke(define_property, [])
      assert {:ok, 0} = Compiler.invoke(non_enumerable, [])
    end

    test "compiles Proxy construct traps", %{rt: rt} do
      construct_trap =
        compile_and_decode(
          rt,
          "let F=new Proxy(function(x){this.x=x},{construct(t,args){return {x:7}}}); new F(1).x"
        ).value

      default_construct =
        compile_and_decode(rt, "let F=new Proxy(function(x){this.x=x},{}); new F(3).x").value

      reflect_construct =
        compile_and_decode(
          rt,
          "let F=new Proxy(function(x){this.x=x},{construct(t,args){return {x:8}}}); Reflect.construct(F,[1]).x"
        ).value

      assert {:ok, 7} = Compiler.invoke(construct_trap, [])
      assert {:ok, 3} = Compiler.invoke(default_construct, [])
      assert {:ok, 8} = Compiler.invoke(reflect_construct, [])
    end

    test "compiles callable Proxy apply traps", %{rt: rt} do
      apply_trap =
        compile_and_decode(
          rt,
          "let f=new Proxy(function(x){return x+1},{apply(t,thisArg,args){return 5}}); f(1)"
        ).value

      default_apply =
        compile_and_decode(rt, "let f=new Proxy(function(x){return x+1},{}); f(1)").value

      args_apply =
        compile_and_decode(
          rt,
          "let f=new Proxy(function(x){return x+1},{apply(t,thisArg,args){return args[0]+2}}); f(3)"
        ).value

      assert {:ok, 5} = Compiler.invoke(apply_trap, [])
      assert {:ok, 2} = Compiler.invoke(default_apply, [])
      assert {:ok, 5} = Compiler.invoke(args_apply, [])
    end

    test "compiles basic Proxy get and has traps", %{rt: rt} do
      proxy_get =
        compile_and_decode(rt, "let p=new Proxy({},{get(t,k){return k==='x'?3:undefined}}); p.x").value

      proxy_has =
        compile_and_decode(rt, "let p=new Proxy({}, {has(){return false}}); 'x' in p").value

      assert {:ok, 3} = Compiler.invoke(proxy_get, [])
      assert {:ok, false} = Compiler.invoke(proxy_has, [])
    end

    test "compiles runtime constructor and regexp feature calls", %{rt: rt} do
      url_can_parse = compile_and_decode(rt, "URL.canParse('https://x.test/')").value
      event_type = compile_and_decode(rt, "new Event('tick', {bubbles:true}).type").value
      event_bubbles = compile_and_decode(rt, "new Event('tick', {bubbles:true}).bubbles").value
      dot_all = compile_and_decode(rt, "/a.b/s.test('a\\nb')").value
      regexp_flags = compile_and_decode(rt, "/./su.flags").value

      assert {:ok, true} = Compiler.invoke(url_can_parse, [])
      assert {:ok, "tick"} = Compiler.invoke(event_type, [])
      assert {:ok, true} = Compiler.invoke(event_bubbles, [])
      assert {:ok, true} = Compiler.invoke(dot_all, [])
      assert {:ok, "su"} = Compiler.invoke(regexp_flags, [])
    end

    test "compiles function calls through arguments", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(f,x){return f(x)})") |> user_function()
      callback = {:builtin, "double", fn [x], _ -> x * 2 end}

      assert {:ok, 8} = Compiler.invoke(fun, [callback, 4])
    end

    test "uses global this for direct function calls", %{rt: rt} do
      sloppy = compile_and_decode(rt, "function f(){ return this===globalThis}; f()").value

      strict =
        compile_and_decode(rt, "function f(){'use strict'; return this===undefined}; f()").value

      assert {:ok, true} = Compiler.invoke(sloppy, [])
      assert {:ok, false} = Compiler.invoke(strict, [])
    end

    test "compiles Map and Set mutation helpers", %{rt: rt} do
      map_set_get = compile_and_decode(rt, "let m=new Map(); m.set(1,2).set(3,4); m.get(3)").value
      map_delete = compile_and_decode(rt, "let m=new Map([[1,2]]); m.delete(1); m.has(1)").value
      map_size = compile_and_decode(rt, "let m=new Map([[1,2],[3,4]]); m.size").value
      set_size = compile_and_decode(rt, "let s=new Set([1,2,2]); s.size").value
      set_delete = compile_and_decode(rt, "let s=new Set([1]); s.delete(1); s.has(1)").value

      weakmap_delete =
        compile_and_decode(rt, "let k={}; let m=new WeakMap([[k,1]]); m.delete(k); m.has(k)").value

      weakset_delete =
        compile_and_decode(rt, "let k={}; let s=new WeakSet([k]); s.delete(k); s.has(k)").value

      assert {:ok, 4} = Compiler.invoke(map_set_get, [])
      assert {:ok, false} = Compiler.invoke(map_delete, [])
      assert {:ok, 2} = Compiler.invoke(map_size, [])
      assert {:ok, 2} = Compiler.invoke(set_size, [])
      assert {:ok, false} = Compiler.invoke(set_delete, [])
      assert {:ok, false} = Compiler.invoke(weakmap_delete, [])
      assert {:ok, false} = Compiler.invoke(weakset_delete, [])
    end

    test "compiles tagged template call semantics", %{rt: rt} do
      tag_this = compile_and_decode(rt, "function tag(){return this===globalThis}; tag`x`").value

      tag_length =
        compile_and_decode(rt, "function tag(strings){return strings.length}; tag`a${1}b`").value

      tag_expr =
        compile_and_decode(
          rt,
          "function tag(strings, v){return strings[0]+v+strings[1]}; tag`a${2}b`"
        ).value

      assert {:ok, true} = Compiler.invoke(tag_this, [])
      assert {:ok, 2} = Compiler.invoke(tag_length, [])
      assert {:ok, "a2b"} = Compiler.invoke(tag_expr, [])
    end

    test "compiles static block object and constructor side effects", %{rt: rt} do
      object_state =
        compile_and_decode(rt, "let state={x:0}; class A{ static { state.x=1 } }; state.x").value

      receiver_prop = compile_and_decode(rt, "class A{ static { this.x=2 } }; A.x").value

      field_order =
        compile_and_decode(rt, "class A{ static x=1; static { this.x+=2 } }; A.x").value

      assert {:ok, 1} = Compiler.invoke(object_state, [])
      assert {:ok, 2} = Compiler.invoke(receiver_prop, [])
      assert {:ok, 3} = Compiler.invoke(field_order, [])
    end

    test "compiles boxed primitive prototype methods", %{rt: rt} do
      assert_compiled = fn source, expected ->
        fun = compile_and_decode(rt, source).value
        assert {:ok, expected} == Compiler.invoke(fun, [])
      end

      assert_compiled.("new Number(3).valueOf()", 3)
      assert_compiled.("new Number(10).toString(16)", "a")
      assert_compiled.("new String('x').valueOf()", "x")
      assert_compiled.("new String('x').concat('y')", "xy")
      assert_compiled.("new String('abc').length", 3)
      assert_compiled.("Object('abc').length", 3)
      assert_compiled.("new String('😀').length", 2)
      assert_compiled.("new Boolean(false).valueOf()", false)
      assert_compiled.("new Boolean(false).toString()", "false")
      assert_compiled.("new Number(1.25).toFixed(1)", "1.3")
      assert_compiled.("new Number(1.25).toPrecision(2)", "1.3")
      assert_compiled.("new Boolean(true).toString()", "true")
      assert_compiled.("Object(4).valueOf()", 4)
      assert_compiled.("Object('x').valueOf()", "x")
    end

    test "compiles Symbol.hasInstance overrides", %{rt: rt} do
      class_override =
        compile_and_decode(
          rt,
          "class C{}; Object.defineProperty(C, Symbol.hasInstance, {value(){return true}}); ({} instanceof C)"
        ).value

      function_override =
        compile_and_decode(
          rt,
          "function C(){}; Object.defineProperty(C, Symbol.hasInstance, {value(){return true}}); ({} instanceof C)"
        ).value

      false_override =
        compile_and_decode(
          rt,
          "function C(){}; Object.defineProperty(C, Symbol.hasInstance, {value(){return false}}); new C() instanceof C"
        ).value

      assert {:ok, true} = Compiler.invoke(class_override, [])
      assert {:ok, true} = Compiler.invoke(function_override, [])
      assert {:ok, false} = Compiler.invoke(false_override, [])
    end

    test "compiles Symbol and BigInt runtime edges", %{rt: rt} do
      symbol_for = compile_and_decode(rt, "Symbol.for('x')===Symbol.for('x')").value
      symbol_key = compile_and_decode(rt, "Symbol.keyFor(Symbol.for('x'))").value
      symbol_description = compile_and_decode(rt, "Symbol('x').description").value
      bigint_to_string = compile_and_decode(rt, "(10n).toString()").value
      bigint_add = compile_and_decode(rt, "1n + 2n").value

      assert {:ok, true} = Compiler.invoke(symbol_for, [])
      assert {:ok, "x"} = Compiler.invoke(symbol_key, [])
      assert {:ok, "x"} = Compiler.invoke(symbol_description, [])
      assert {:ok, "10"} = Compiler.invoke(bigint_to_string, [])
      assert {:ok, {:bigint, 3}} = Compiler.invoke(bigint_add, [])
    end

    test "compiles TDZ and nested private-brand edges", %{rt: rt} do
      typeof_tdz = compile_and_decode(rt, "try { typeof x } catch(e) { e.name } let x=1").value
      assert {:ok, "undefined"} = Compiler.invoke(typeof_tdz, [])

      private_in =
        compile_and_decode(rt, "class A{ #x; static has(o){return #x in o} } A.has(new A())").value

      assert {:ok, true} = Compiler.invoke(private_in, [])

      nested_private =
        compile_and_decode(
          rt,
          "class A{ #x=1; m(){ class B{ n(o){ return o.#x } } return new B().n(this) } } new A().m()"
        ).value

      assert {:ok, 1} = Compiler.invoke(nested_private, [])
    end

    test "fuses captured var-ref calls into one runtime helper", %{rt: rt} do
      outer =
        compile_and_decode(rt, "(function(f){ return function(x){ return f(x) } })")
        |> user_function()

      inner = Enum.find(outer.constants, &match?(%Bytecode.Function{closure_vars: [_ | _]}, &1))
      assert %Bytecode.Function{} = inner

      assert {:ok, beam_file} = Compiler.disasm(inner)
      block = beam_function_instructions(beam_file, :block_0)

      assert Enum.any?(block, fn
               {:call_ext, 2, {:extfunc, QuickBEAM.VM.Compiler.RuntimeHelpers, :get_capture, 2}} ->
                 true

               {:call_ext_last, 2,
                {:extfunc, QuickBEAM.VM.Compiler.RuntimeHelpers, :get_capture, 2}, _} ->
                 true

               _ ->
                 false
             end)

      callback = {:builtin, "double", fn [x], _ -> x * 2 end}
      assert {:ok, {:closure, _, _} = closure} = Compiler.invoke(outer, [callback])
      assert {:ok, 8} = Compiler.invoke(closure, [4])
    end

    test "compiles captured var-ref calls with more than three arguments", %{rt: rt} do
      outer =
        compile_and_decode(rt, "(function(f){ return function(a,b,c,d){ return f(a,b,c,d) } })")
        |> user_function()

      callback = {:builtin, "sum4", fn [a, b, c, d], _ -> a + b + c + d end}
      assert {:ok, {:closure, _, _} = closure} = Compiler.invoke(outer, [callback])
      assert {:ok, 10} = Compiler.invoke(closure, [1, 2, 3, 4])
    end

    test "compiles transitive captured closures", %{rt: rt} do
      outer =
        compile_and_decode(
          rt,
          "(function(f){ return function(){ return function(x){ return f(x) } } })"
        )
        |> user_function()

      callback = {:builtin, "double", fn [x], _ -> x * 2 end}
      assert {:ok, {:closure, _, _} = mid} = Compiler.invoke(outer, [callback])
      assert {:ok, {:closure, _, _} = inner} = Compiler.invoke(mid, [])
      assert {:ok, 8} = Compiler.invoke(inner, [4])
    end

    test "reads fresh values from captured local cells", %{rt: rt} do
      direct =
        compile_and_decode(rt, "function f(){let x=0; function r(){x=1}; r(); return x}; f()").value

      increment =
        compile_and_decode(rt, "function f(){let x=1; function r(){x++}; r(); return x}; f()").value

      compound =
        compile_and_decode(rt, "function f(){let x=1; function r(){x+=2}; r(); return x}; f()").value

      nested =
        compile_and_decode(
          rt,
          "function f(){let x=0; function r(){x=1}; function s(){r()}; s(); return x}; f()"
        ).value

      assert {:ok, 1} = Compiler.invoke(direct, [])
      assert {:ok, 2} = Compiler.invoke(increment, [])
      assert {:ok, 3} = Compiler.invoke(compound, [])
      assert {:ok, 1} = Compiler.invoke(nested, [])
    end

    test "keeps capture keys distinct for same bytecode closures", %{rt: rt} do
      inline =
        compile_and_decode(
          rt,
          "function f(){let a=1,b=2; let g=()=>a; let h=()=>b; return g()+h()} f()"
        ).value

      returned =
        compile_and_decode(
          rt,
          "function f(){let a=1,b=2; return [()=>a,()=>b]} let p=f(); p[0]()+p[1]()"
        ).value

      assert {:ok, 3} = Compiler.invoke(inline, [])
      assert {:ok, 3} = Compiler.invoke(returned, [])
    end

    test "compiles method calls with receiver", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o,x){return o.inc(x)})") |> user_function()

      assert {:ok, beam_file} = Compiler.disasm(fun)
      refute {RuntimeHelpers, :invoke_method_runtime, 4} in beam_extfuncs(beam_file)

      obj =
        Heap.wrap(%{
          "base" => 10,
          "inc" => {:builtin, "inc", fn [x], this -> Get.get(this, "base") + x end}
        })

      assert {:ok, 13} = Compiler.invoke(fun, [obj, 3])
    end

    test "compiles global lookup plus method call", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){return Math.abs(x)})") |> user_function()

      assert {:ok, 12} = Compiler.invoke(fun, [-12])
    end

    test "keeps atom tables distinct for identical top-level bytecode", %{rt: rt} do
      abc = compile_and_decode(rt, "new String('abc').length").value
      emoji = compile_and_decode(rt, "new String('😀').length").value

      assert {:ok, 3} = Compiler.invoke(abc, [])
      assert {:ok, 2} = Compiler.invoke(emoji, [])
    end

    test "keeps atom tables distinct for same bytecode callbacks", %{rt: rt} do
      find = compile_and_decode(rt, "[1,2,3].find(x=>x>1)").value
      some = compile_and_decode(rt, "[1,2,3].some(x=>x>2)").value
      every = compile_and_decode(rt, "[1,2,3].every(x=>x>0)").value
      reduce = compile_and_decode(rt, "[1,2,3].reduce((a,b)=>a+b,0)").value

      assert {:ok, 2} = Compiler.invoke(find, [])
      assert {:ok, true} = Compiler.invoke(some, [])
      assert {:ok, true} = Compiler.invoke(every, [])
      assert {:ok, 6} = Compiler.invoke(reduce, [])
    end

    test "compiles array writes with indexed reads", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(v){ let a=[]; a[0]=v; return a[0] })")
        |> user_function()

      assert {:ok, 11} = Compiler.invoke(fun, [11])
    end

    test "compiles compound array updates", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,v){ a[0] += v; return a[0] })") |> user_function()

      assert {:ok, 8} = Compiler.invoke(fun, [Heap.wrap([3]), 5])
    end

    test "compiles loose-null checks before indexed writes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(i,v){ if (i == null) i = 0; let a=[]; a[i]=v; return a[i] })"
        )
        |> user_function()

      assert {:ok, 12} = Compiler.invoke(fun, [nil, 12])
      assert {:ok, 13} = Compiler.invoke(fun, [1, 13])
    end

    test "compiles local increments", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ x++; return x })") |> user_function()

      assert {:ok, 6} = Compiler.invoke(fun, [5])
    end

    test "compiles post-increment expression results", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return x++ })") |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [5])
    end

    test "compiles exponentiation", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){ return a ** b })") |> user_function()

      assert {:ok, 8.0} = Compiler.invoke(fun, [2, 3])
    end

    test "compiles bitwise operators", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(a,b){ return ((a & b) ^ 1) << 2 })") |> user_function()

      assert {:ok, 0} = Compiler.invoke(fun, [3, 1])
    end

    test "compiles modulo", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){ return a % b })") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [10, 3])
    end

    test "compiles logical not", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return !x })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [0])
      assert {:ok, false} = Compiler.invoke(fun, [1])
    end

    test "compiles bitwise not", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return ~x })") |> user_function()

      assert {:ok, -6} = Compiler.invoke(fun, [5])
    end

    test "compiles typeof", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return typeof x })") |> user_function()

      assert {:ok, "number"} = Compiler.invoke(fun, [5])
      assert {:ok, "undefined"} = Compiler.invoke(fun, [:undefined])
    end

    test "compiles specialized typeof comparisons", %{rt: rt} do
      function_fun =
        compile_and_decode(rt, "(function(x){ return typeof x === 'function' })")
        |> user_function()

      undefined_fun =
        compile_and_decode(rt, "(function(x){ return typeof x === 'undefined' })")
        |> user_function()

      assert {:ok, true} =
               Compiler.invoke(function_fun, [{:builtin, "noop", fn _, _ -> :undefined end}])

      assert {:ok, false} = Compiler.invoke(function_fun, [5])
      assert {:ok, true} = Compiler.invoke(undefined_fun, [:undefined])
      assert {:ok, true} = Compiler.invoke(undefined_fun, [nil])
      assert {:ok, false} = Compiler.invoke(undefined_fun, [0])
    end

    test "compiles null checks", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return x === null })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [nil])
      assert {:ok, false} = Compiler.invoke(fun, [:undefined])
    end

    test "compiles in operator", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(k,o){ return k in o })") |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, ["x", Heap.wrap(%{"x" => 1})])
      assert {:ok, false} = Compiler.invoke(fun, ["y", Heap.wrap(%{"x" => 1})])
    end

    test "compiles delete with atom property names", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ delete o.x; return o.x })") |> user_function()

      assert {:ok, :undefined} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles array element delete as a hole", %{rt: rt} do
      missing = compile_and_decode(rt, "let a=[1]; delete a[0]; 0 in a").value
      read = compile_and_decode(rt, "let a=[1]; delete a[0]; a[0] === undefined").value
      length = compile_and_decode(rt, "let a=[1,2]; delete a[0]; a.length").value

      assert {:ok, false} = Compiler.invoke(missing, [])
      assert {:ok, true} = Compiler.invoke(read, [])
      assert {:ok, 2} = Compiler.invoke(length, [])
    end

    test "compiles instanceof", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(obj, ctor){ return obj instanceof ctor })")
        |> user_function()

      parent_proto = Heap.wrap(%{})
      child = Heap.wrap(%{proto() => parent_proto})
      ctor = Heap.wrap(%{"prototype" => parent_proto})

      assert {:ok, true} = Compiler.invoke(fun, [child, ctor])
      assert {:ok, false} = Compiler.invoke(fun, [5, ctor])
    end

    test "compiles instanceof through prototype chains", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(obj, ctor){ return obj instanceof ctor })")
        |> user_function()

      parent_proto = Heap.wrap(%{})
      mid_proto = Heap.wrap(%{proto() => parent_proto})
      child = Heap.wrap(%{proto() => mid_proto})
      ctor = Heap.wrap(%{"prototype" => parent_proto})

      assert {:ok, true} = Compiler.invoke(fun, [child, ctor])
    end

    test "compiles constructor calls", %{rt: rt} do
      ctor = compile_and_decode(rt, "(function A(x){ this.x = x })") |> user_function()
      fun = compile_and_decode(rt, "(function(C,x){ return new C(x).x })") |> user_function()

      assert {:ok, 9} = Compiler.invoke(fun, [ctor, 9])
    end

    test "compiles constructor calls without arguments", %{rt: rt} do
      ctor = compile_and_decode(rt, "(function A(){ this.x = 1 })") |> user_function()
      fun = compile_and_decode(rt, "(function(C){ return new C().x })") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [ctor])
    end

    test "compiles constructor calls used in later control flow", %{rt: rt} do
      ctor = compile_and_decode(rt, "(function A(x){ this.x = x })") |> user_function()

      fun =
        compile_and_decode(
          rt,
          "(function(C,x){ const o = {}; o.value = new C(x); let i = 0; if (i < x) return o.value.x; return 0 })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [ctor, 7])
    end

    test "compiles wrapped non-capturing closures", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(x){ return x + 1 })") |> user_function()

      assert {:ok, 6} = Compiler.invoke({:closure, %{}, fun}, [5])

      assert match?(
               {:compiled, _, _},
               Heap.get_compiled(compiled_key(fun))
             )
    end

    test "compiles class constructor closures without var ref reads", %{rt: rt} do
      outer =
        compile_and_decode(
          rt,
          "(function(){ class A { constructor(x){ this.x = x } } return A })"
        )
        |> user_function()

      ctor =
        Enum.find(outer.constants, fn
          %Bytecode.Function{source: source} when is_binary(source) ->
            String.contains?(source, "constructor")

          _ ->
            false
        end)

      assert %Bytecode.Function{var_ref_count: 0} = ctor

      closure = {:closure, %{}, ctor}

      assert {:obj, ref} = RuntimeHelpers.construct_runtime(closure, closure, [9])
      assert 9 == Heap.get_obj(ref)["x"]

      assert match?(
               {:compiled, _, _},
               Heap.get_compiled(compiled_key(ctor))
             )
    end

    test "compiles array spread", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a){ return [...a].length })") |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [Heap.wrap([1, 2, 3])])
    end

    test "compiles string array spread", %{rt: rt} do
      ascii = compile_and_decode(rt, "[...'ab'].join('')").value
      astral = compile_and_decode(rt, "[...'😀'].length").value

      assert {:ok, "ab"} = Compiler.invoke(ascii, [])
      assert {:ok, 1} = Compiler.invoke(astral, [])
    end

    test "compiled cache keys include atom tables", %{rt: rt} do
      pad_start = compile_and_decode(rt, "'x'.padStart(3,'a')").value
      assert {:ok, "aax"} = Compiler.invoke(pad_start, [])

      pad_end = compile_and_decode(rt, "'x'.padEnd(3,'a')").value
      assert {:ok, "xaa"} = Compiler.invoke(pad_end, [])
    end

    test "compiles object spread", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ return {...o}.x })") |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles object spread followed by field definition", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ return {...o, y:1}.y })") |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [Heap.wrap(%{"x" => 7})])
    end

    test "compiles for-of loops over arrays", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(a){ let s=0; for (const x of a) s += x; return s })")
        |> user_function()

      assert {:ok, 10} = Compiler.invoke(fun, [Heap.wrap([1, 2, 3, 4])])
    end

    test "compiles for-of loops over strings", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(s){ let out=''; for (const ch of s) out += ch; return out })"
        )
        |> user_function()

      assert {:ok, "abc"} = Compiler.invoke(fun, ["abc"])
    end

    test "calls custom iterator methods with the iterator receiver", %{rt: rt} do
      source =
        "let state={closed:0}; let it={ [Symbol.iterator](){return this}, next(){return {value:1,done:false}}, return(){state.closed=1; return {done:true}}}; for (let x of it) { break; } state.closed"

      fun = compile_and_decode(rt, source).value

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "closes custom iterators during destructuring", %{rt: rt} do
      source =
        "let state={closed:0}; let it={ [Symbol.iterator](){return this}, next(){return {value:1,done:false}}, return(){state.closed=1; return {done:true}}}; let [x] = it; state.closed"

      fun = compile_and_decode(rt, source).value

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "iterates astral strings by codepoint", %{rt: rt} do
      fun =
        compile_and_decode(rt, "let out=[]; for (let ch of '😀a') out.push(ch); out.length").value

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles try catch around explicit throws", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(e){ try { throw e } catch(err) { return err } })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [7])
    end

    test "compiles try catch around throwing calls", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(f){ try { return f() } catch(err) { return err } })")
        |> user_function()

      throwing_fun = {:builtin, "boom", fn [], _ -> throw({:js_throw, 11}) end}

      assert {:ok, 11} = Compiler.invoke(fun, [throwing_fun])
    end

    test "compiles nested try catch rethrows", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(f){ try { try { return f() } catch(err) { throw err } } catch(err) { return err } })"
        )
        |> user_function()

      throwing_fun = {:builtin, "boom", fn [], _ -> throw({:js_throw, 13}) end}

      assert {:ok, 13} = Compiler.invoke(fun, [throwing_fun])
    end

    test "compiles for-in loops over object keys", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(o){ let s=''; for (const k in o) s += k; return s })")
        |> user_function()

      assert {:ok, "ab"} = Compiler.invoke(fun, [Heap.wrap(%{"a" => 1, "b" => 2})])
    end

    test "compiles for-in loops over array indexes", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(a){ let s=''; for (const k in a) s += k; return s })")
        |> user_function()

      assert {:ok, "012"} = Compiler.invoke(fun, [Heap.wrap([10, 20, 30])])
    end

    test "compiles empty for-in fallthrough", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(o){ for (const k in o) return k; return 'none' })")
        |> user_function()

      assert {:ok, "none"} = Compiler.invoke(fun, [Heap.wrap(%{})])
    end

    test "compiles try finally with side effects", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ var x=0; try { x=1 } finally { x=2 } return x })")
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles try catch finally", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ var x=0; try { throw 'err' } catch(e) { x=1 } finally { x+=1 } return x })"
        )
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles try finally around returns", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(f){ try { return f() } finally { 1 } })")
        |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [{:builtin, "five", fn [], _ -> 5 end}])
    end

    test "compiles nested plain functions", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ function f(a,b){ return a+b } return f(1,2) })")
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles nested rest-parameter functions", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ function f(...args){ return args.length } return f(1,2,3) })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles nested default-parameter functions", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ function f(a,b=10){ return a+b } return f(5) })")
        |> user_function()

      assert {:ok, 15} = Compiler.invoke(fun, [])
    end

    test "compiles nested captured-argument functions", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){ function f(y){ return x+y } return f(2) })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [5])
    end

    test "compiles nested captured-local updates", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(x){ let y=x; function f(z){ return y+z } y=5; return f(2) })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [1])
    end

    test "compiles nested closures that mutate captured locals", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ let x=1; function f(){ x+=1; return x } return f()+f() })"
        )
        |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [])
    end

    test "compiles arrow closures with inferred names", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){ const f = (y) => x + y; return f(2) })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [5])
    end

    test "compiles object literal methods", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ return { m(){ return 1 } }.m() })")
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles object literal methods with captures", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(x){ return { m(y){ return x+y } }.m(2) })")
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [5])
    end

    test "compiles computed object literal methods", %{rt: rt} do
      fun =
        compile_and_decode(rt, ~s|(function(){ return ({ ["m"](){ return 1 } })["m"]() })|)
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles computed-name function expressions", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          ~s|(function(){ const n = "x"; return ({ [n]: function(){ return 1 } })[n]() })|
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles simple classes", %{rt: rt} do
      fun =
        compile_and_decode(rt, "(function(){ class A { m(){ return 1 } } return new A().m() })")
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "keeps class prototype methods non-enumerable", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { m(){ return 1 } } return [Object.keys(A.prototype).length, A.prototype.propertyIsEnumerable(\"constructor\"), A.prototype.propertyIsEnumerable(\"m\")] })"
        )
        |> user_function()

      assert {:ok, {:obj, ref}} = Compiler.invoke(fun, [])
      assert [0, false, false] = Heap.to_list({:obj, ref})
    end

    test "keeps class prototype accessors non-enumerable", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { get x(){ return 1 } set x(v){} } return [Object.keys(A.prototype).length, A.prototype.propertyIsEnumerable(\"x\")] })"
        )
        |> user_function()

      assert {:ok, {:obj, ref}} = Compiler.invoke(fun, [])
      assert [0, false] = Heap.to_list({:obj, ref})
    end

    test "compiles classes with constructors", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { constructor(x){ this.x=x } } return new A(3).x })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles class inheritance with super methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { m(){ return 1 } } class B extends A { m(){ return super.m()+1 } } return new B().m() })"
        )
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "compiles private field classes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 42; get() { return this.#x } } return new A().get() })"
        )
        |> user_function()

      assert {:ok, 42} = Compiler.invoke(fun, [])
    end

    test "compiles private field setters", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 0; set(v) { this.#x = v } get() { return this.#x } } var a = new A(); a.set(99); return a.get() })"
        )
        |> user_function()

      assert {:ok, 99} = Compiler.invoke(fun, [])
    end

    test "compiles private methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m() { return 3 } get() { return this.#m() } } return new A().get() })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles private accessors", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { get #x() { return 7 } read() { return this.#x } } return new A().read() })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [])
    end

    test "compiles private static fields", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 42; static get() { return A.#x } } return A.get() })"
        )
        |> user_function()

      assert {:ok, 42} = Compiler.invoke(fun, [])
    end

    test "compiles private static writes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static set(v){ A.#x = v } static get(){ return A.#x } } A.set(9); return A.get() })"
        )
        |> user_function()

      assert {:ok, 9} = Compiler.invoke(fun, [])
    end

    test "compiles private static methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #m(){ return 5 } static get(){ return A.#m() } } return A.get() })"
        )
        |> user_function()

      assert {:ok, 5} = Compiler.invoke(fun, [])
    end

    test "compiles private static accessors", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static get #x(){ return 7 } static read(){ return A.#x } } return A.read() })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [])
    end

    test "compiles private static in checks", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static has(){ return #x in A } } return A.has() })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private field receivers", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; get(){ return this.#x } } const g = (new A()).get; try { return g.call({}) } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private method receivers", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m(){ return 1 } get(){ return this.#m() } } const g = (new A()).get; try { return g.call({}) } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private receivers across classes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; get(o){ try { return o.#x } catch (e) { return e instanceof TypeError } } } class B {} return new A().get(new B()) })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private static receivers across classes", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static get(o){ try { return o.#x } catch (e) { return e instanceof TypeError } } } class B {} return A.get(B) })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "rejects invalid private setters", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; set(v){ this.#x = v } } const s = (new A()).set; try { s.call({}, 2); return false } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "supports private members on subclass instances", %{rt: rt} do
      field_fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #x = 1; get(){ return this.#x } } class B extends A {} return new B().get() })"
        )
        |> user_function()

      method_fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m(){ return 1 } call(){ return this.#m() } } class B extends A {} return new B().call() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(field_fun, [])
      assert {:ok, 1} = Compiler.invoke(method_fun, [])
    end

    test "rejects inherited private static access", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static get(){ return this.#x } } class B extends A {} try { return B.get() } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "inherits static methods named call", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static call(){ return 1 } } class B extends A {} return B.call() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "rejects inherited private static methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #m(){ return 1 } static call(){ return this.#m() } } class B extends A {} try { return B.call() } catch (e) { return e instanceof TypeError } })"
        )
        |> user_function()

      assert {:ok, true} = Compiler.invoke(fun, [])
    end

    test "compiles private static blocks", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static #x = 1; static { this.#x += 2 } static get(){ return this.#x } } return A.get() })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles private super calls", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { #m(){ return 1 } call(){ return this.#m() } } class B extends A { call2(){ return super.call() } } return new B().call2() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles static super setters", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static set x(v){ this.y = v + 1 } } class B extends A { static g(){ super.x = 2; return this.y } } return B.g() })"
        )
        |> user_function()

      assert {:ok, 3} = Compiler.invoke(fun, [])
    end

    test "compiles static super getters", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static get x(){ return this.y } } class B extends A { static y = 7; static g(){ return super.x } } return B.g() })"
        )
        |> user_function()

      assert {:ok, 7} = Compiler.invoke(fun, [])
    end

    test "compiles computed static methods", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { static [\"m\"](){ return 1 } } return A.m() })"
        )
        |> user_function()

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "propagates new.target through derived super calls", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { constructor(){ this.v = new.target.name } } class B extends A { constructor(...args){ super(...args) } } return new B().v })"
        )
        |> user_function()

      assert {:ok, "B"} = Compiler.invoke(fun, [])
    end

    test "compiles with-scope property assignment references", %{rt: rt} do
      assignment = compile_and_decode(rt, "let o={x:1}; with(o){ x=2; } o.x").value
      update = compile_and_decode(rt, "let o={x:1}; with(o){ x++; } o.x").value

      global_fallback = compile_and_decode(rt, "var x=1; let o={}; with(o){ x=2; } x").value

      unscopables_fallback =
        compile_and_decode(
          rt,
          "var x=1; let o={x:2, [Symbol.unscopables]: {x:true}}; with(o){ x=3; } [x,o.x]"
        ).value

      assert {:ok, 2} = Compiler.invoke(assignment, [])
      assert {:ok, 2} = Compiler.invoke(update, [])
      assert {:ok, 2} = Compiler.invoke(global_fallback, [])
      assert {:ok, {:obj, array_ref}} = Compiler.invoke(unscopables_fallback, [])
      assert [3, 2] = array_ref |> Heap.get_obj() |> QuickBEAM.VM.Heap.Arrays.to_list()
    end

    test "compiles with-scope property reads with fallback branches", %{rt: rt} do
      direct_read = compile_and_decode(rt, "let o={x:2}; with(o){ x }").value
      base_read = compile_and_decode(rt, "let o={a:{m(){return 7}}}; with(o){ a.m() }").value
      fallback_read = compile_and_decode(rt, "let o={}; let x=1; with(o){ x }").value

      assert {:ok, 2} = Compiler.invoke(direct_read, [])
      assert {:ok, 7} = Compiler.invoke(base_read, [])
      assert {:ok, 1} = Compiler.invoke(fallback_read, [])
    end

    test "keeps eval-scope with assignments compilable", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "function f(){ var x=1; function g(){ eval(''); x=2; return x }; return g() } f()"
        ).value

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "resumes compiled generators at first yield", %{rt: rt} do
      fun =
        compile_and_decode(rt, "function* g(){ yield 1; return 2 } let it=g(); it.next().value").value

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "returns resolved values from compiled async functions", %{rt: rt} do
      fun = compile_and_decode(rt, "async function f(){ return 1 } f()").value

      assert {:ok, 1} = Compiler.invoke(fun, [])
    end

    test "compiles promise combinator rejection flows", %{rt: rt} do
      all_settled =
        compile_and_decode(
          rt,
          ~S|Promise.allSettled([Promise.resolve(1), Promise.reject(2)]).then(r=>r[0].status + ":" + r[1].reason)|
        ).value

      any =
        compile_and_decode(
          rt,
          ~S|Promise.any([Promise.reject(1), Promise.resolve(2)]).then(x=>x+1)|
        ).value

      race_reject =
        compile_and_decode(
          rt,
          ~S|Promise.race([Promise.reject(1), Promise.resolve(2)]).catch(e=>e+1)|
        ).value

      race_resolve =
        compile_and_decode(
          rt,
          ~S|Promise.race([Promise.resolve(2), Promise.reject(1)]).then(x=>x+1)|
        ).value

      all_reject =
        compile_and_decode(
          rt,
          ~S|Promise.all([Promise.resolve(1), Promise.reject(2)]).catch(e=>e+1)|
        ).value

      assert {:ok, "fulfilled:2"} = Compiler.invoke(all_settled, [])
      assert {:ok, 3} = Compiler.invoke(any, [])
      assert {:ok, 2} = Compiler.invoke(race_reject, [])
      assert {:ok, 3} = Compiler.invoke(race_resolve, [])

      any_all_reject =
        compile_and_decode(
          rt,
          ~S|Promise.any([Promise.reject(1), Promise.reject(2)]).catch(e=>e.errors[0]+e.errors[1])|
        ).value

      any_empty = compile_and_decode(rt, ~S|Promise.any([]).catch(e=>e.name)|).value

      assert {:ok, 3} = Compiler.invoke(all_reject, [])
      assert {:ok, 3} = Compiler.invoke(any_all_reject, [])
      assert {:ok, "AggregateError"} = Compiler.invoke(any_empty, [])
    end

    test "normalizes compiled async rejections for promise chains", %{rt: rt} do
      thrown = compile_and_decode(rt, "async function f(){throw 1} f().catch(e=>e+1)").value

      rejected_await =
        compile_and_decode(
          rt,
          "async function f(){return await Promise.reject(1)} f().catch(e=>e+1)"
        ).value

      fulfilled_then =
        compile_and_decode(rt, "async function f(){return 1} f().then(x=>x+1)").value

      returned_rejection =
        compile_and_decode(rt, "async function f(){return Promise.reject(1)} f().catch(e=>e+1)").value

      returned_resolution =
        compile_and_decode(rt, "async function f(){return Promise.resolve(3)} f()").value

      caught_rejected_await =
        compile_and_decode(
          rt,
          "async function f(){try{return await Promise.reject(1)}catch(e){return e+1}} f()"
        ).value

      assert {:ok, 2} = Compiler.invoke(thrown, [])
      assert {:ok, 2} = Compiler.invoke(rejected_await, [])
      assert {:ok, 2} = Compiler.invoke(fulfilled_then, [])
      assert {:ok, 2} = Compiler.invoke(returned_rejection, [])
      assert {:ok, 3} = Compiler.invoke(returned_resolution, [])
      assert {:ok, 2} = Compiler.invoke(caught_rejected_await, [])
    end

    test "enforces frozen target proxy ownKeys invariants", %{rt: rt} do
      missing =
        compile_and_decode(
          rt,
          ~S|let t=Object.freeze({x:1}); let p=new Proxy(t,{ownKeys(){return []}}); try{Reflect.ownKeys(p)}catch(e){e.name}|
        ).value

      extra =
        compile_and_decode(
          rt,
          ~S|let t=Object.freeze({x:1}); let p=new Proxy(t,{ownKeys(){return ["x","y"]}}); try{Reflect.ownKeys(p)}catch(e){e.name}|
        ).value

      exact =
        compile_and_decode(
          rt,
          ~S|let t=Object.freeze({x:1}); let p=new Proxy(t,{ownKeys(){return ["x"]}}); Reflect.ownKeys(p).length|
        ).value

      assert {:ok, "TypeError"} = Compiler.invoke(missing, [])
      assert {:ok, "TypeError"} = Compiler.invoke(extra, [])
      assert {:ok, 1} = Compiler.invoke(exact, [])
    end

    test "rejects duplicate proxy ownKeys trap results", %{rt: rt} do
      duplicate =
        compile_and_decode(
          rt,
          ~S|let p=new Proxy({}, {ownKeys(){return ["x", "x"]}}); try{Reflect.ownKeys(p)}catch(e){e.name}|
        ).value

      distinct =
        compile_and_decode(
          rt,
          ~S|let p=new Proxy({}, {ownKeys(){return ["x", "y"]}}); Reflect.ownKeys(p).length|
        ).value

      assert {:ok, "TypeError"} = Compiler.invoke(duplicate, [])
      assert {:ok, 2} = Compiler.invoke(distinct, [])
    end

    test "enforces proxy ownKeys invariants", %{rt: rt} do
      missing =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false}); let p=new Proxy(t,{ownKeys(){return []}}); try{Reflect.ownKeys(p)}catch(e){e.name}|
        ).value

      included =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false}); let p=new Proxy(t,{ownKeys(){return ["x"]}}); Reflect.ownKeys(p).length|
        ).value

      configurable =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:true}); let p=new Proxy(t,{ownKeys(){return []}}); Reflect.ownKeys(p).length|
        ).value

      assert {:ok, "TypeError"} = Compiler.invoke(missing, [])
      assert {:ok, 1} = Compiler.invoke(included, [])
      assert {:ok, 0} = Compiler.invoke(configurable, [])
    end

    test "enforces proxy set invariants", %{rt: rt} do
      mismatch =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false, writable:false}); let p=new Proxy(t,{set(){return true}}); try{p.x=2; 0}catch(e){e.name}|
        ).value

      same =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false, writable:false}); let p=new Proxy(t,{set(){return true}}); p.x=1; p.x|
        ).value

      false_trap =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false, writable:false}); let p=new Proxy(t,{set(){return false}}); p.x=2; p.x|
        ).value

      assert {:ok, "TypeError"} = Compiler.invoke(mismatch, [])
      assert {:ok, 1} = Compiler.invoke(same, [])
      assert {:ok, 1} = Compiler.invoke(false_trap, [])
    end

    test "enforces proxy get invariants", %{rt: rt} do
      mismatch =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false, writable:false}); let p=new Proxy(t,{get(){return 2}}); try{p.x}catch(e){e.name}|
        ).value

      same =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:false, writable:false}); let p=new Proxy(t,{get(){return 1}}); p.x|
        ).value

      configurable =
        compile_and_decode(
          rt,
          ~S|let t={}; Object.defineProperty(t,"x",{value:1, configurable:true, writable:false}); let p=new Proxy(t,{get(){return 2}}); p.x|
        ).value

      assert {:ok, "TypeError"} = Compiler.invoke(mismatch, [])
      assert {:ok, 1} = Compiler.invoke(same, [])
      assert {:ok, 2} = Compiler.invoke(configurable, [])
    end

    test "supports array Symbol.iterator", %{rt: rt} do
      sum =
        compile_and_decode(
          rt,
          ~S|let it=[1,2][Symbol.iterator](); it.next().value + it.next().value|
        ).value

      symbol_identity =
        compile_and_decode(rt, ~S|let it=[1][Symbol.iterator](); it[Symbol.iterator]() === it|).value

      values_identity =
        compile_and_decode(rt, ~S|let it=[1].values(); it[Symbol.iterator]() === it|).value

      assert {:ok, 3} = Compiler.invoke(sum, [])
      assert {:ok, true} = Compiler.invoke(symbol_identity, [])
      assert {:ok, true} = Compiler.invoke(values_identity, [])
    end

    test "supports boxed string iterators", %{rt: rt} do
      object_box =
        compile_and_decode(
          rt,
          ~S|let it=Object("ab")[Symbol.iterator](); it.next().value + it.next().value|
        ).value

      constructor_box =
        compile_and_decode(
          rt,
          ~S|let it=new String("😀a"); let iter=it[Symbol.iterator](); iter.next().value + iter.next().value|
        ).value

      assert {:ok, "ab"} = Compiler.invoke(object_box, [])
      assert {:ok, "😀a"} = Compiler.invoke(constructor_box, [])
    end

    test "supports direct primitive string iterators", %{rt: rt} do
      astral =
        compile_and_decode(
          rt,
          ~S|let it="😀a"[Symbol.iterator](); it.next().value + it.next().value|
        ).value

      self_iter =
        compile_and_decode(rt, ~S|let it="ab"[Symbol.iterator](); it[Symbol.iterator]() === it|).value

      done =
        compile_and_decode(rt, ~S|let it="a"[Symbol.iterator](); it.next(); it.next().done|).value

      assert {:ok, "😀a"} = Compiler.invoke(astral, [])
      assert {:ok, true} = Compiler.invoke(self_iter, [])
      assert {:ok, true} = Compiler.invoke(done, [])
    end

    test "compiles queueMicrotask interactions", %{rt: rt} do
      deferred_state =
        compile_and_decode(rt, "let state={x:0}; queueMicrotask(()=>{state.x=1}); state.x").value

      promise_observer =
        compile_and_decode(
          rt,
          "let state={x:0}; queueMicrotask(()=>{state.x=1}); Promise.resolve().then(()=>state.x)"
        ).value

      thrown_task =
        compile_and_decode(rt, "let state={x:0}; queueMicrotask(()=>{throw 1}); state.x").value

      assert {:ok, 0} = Compiler.invoke(deferred_state, [])
      assert {:ok, 1} = Compiler.invoke(promise_observer, [])
      assert {:ok, 0} = Compiler.invoke(thrown_task, [])
    end

    test "drains top-level promise continuations", %{rt: rt} do
      rejected_catch = compile_and_decode(rt, "Promise.reject(1).catch(e=>e+1)").value

      thrown_catch =
        compile_and_decode(rt, "Promise.resolve(1).then(()=>{throw 2}).catch(e=>e+1)").value

      awaited_chain =
        compile_and_decode(
          rt,
          "async function f(){ return await Promise.reject(1).catch(e=>e+1)} f()"
        ).value

      assert {:ok, 2} = Compiler.invoke(rejected_catch, [])
      assert {:ok, [1]} = Compiler.invoke(thrown_catch, [])
      assert {:ok, 2} = Compiler.invoke(awaited_chain, [])
    end

    test "returns resolved values from compiled async methods", %{rt: rt} do
      object_method = compile_and_decode(rt, "let o={async m(){return await 11}}; o.m()").value

      class_method =
        compile_and_decode(rt, "class A { async m(){return await 12} } new A().m()").value

      assert {:ok, 11} = Compiler.invoke(object_method, [])
      assert {:ok, 12} = Compiler.invoke(class_method, [])
    end

    test "compiles derived constructors returning objects", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ class A { constructor(){ this.a = 1 } } class B extends A { constructor(){ super(); return {b:2} } } return new B().b })"
        )
        |> user_function()

      assert {:ok, 2} = Compiler.invoke(fun, [])
    end

    test "preserves inner class expression names", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ const C = class D { static n(){ return D.name } }; return C.n() })"
        )
        |> user_function()

      assert {:ok, "D"} = Compiler.invoke(fun, [])
    end

    test "compiles computed static fields", %{rt: rt} do
      fun =
        compile_and_decode(
          rt,
          "(function(){ const k = \"x\"; class A { static [k] = 4 } return A.x })"
        )
        |> user_function()

      assert {:ok, 4} = Compiler.invoke(fun, [])
    end

    test "preserves side-effectful dropped method calls", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(o){ o.bump(); return o.n })") |> user_function()

      obj =
        Heap.wrap(%{
          "n" => 0,
          "bump" =>
            {:builtin, "bump",
             fn [], {:obj, ref} ->
               Heap.put_obj(ref, Map.put(Heap.get_obj(ref, %{}), "n", 1))
               :undefined
             end}
        })

      assert {:ok, 1} = Compiler.invoke(fun, [obj])
    end
  end

  describe "Interpreter integration" do
    test "eligible functions use the compiled cache", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(a,b){return a+b})")
      fun = user_function(parsed)

      assert 9 == Interpreter.invoke(fun, [4, 5], 1_000)

      assert {:compiled, {_mod, :run_ctx}, _atoms} =
               Heap.get_compiled(compiled_key(fun))
    end

    test "branchy functions also use the compiled cache", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(x){if(x>0)return 1;else return 2})")
      fun = user_function(parsed)

      assert 1 == Interpreter.invoke(fun, [5], 1_000)

      assert {:compiled, {_mod, :run_ctx}, _atoms} =
               Heap.get_compiled(compiled_key(fun))
    end
  end
end
