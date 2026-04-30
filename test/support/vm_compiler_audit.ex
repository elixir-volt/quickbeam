defmodule QuickBEAM.VM.CompilerAudit do
  @moduledoc false

  alias QuickBEAM.VM.{Bytecode, Compiler, Heap, Interpreter}
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

  def run_all do
    Enum.map(cases(), fn {name, source} -> run_case(name, source) end)
  end

  def run_case(name, source) do
    with {:ok, parsed} <- compile_source(source) do
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
    else
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
      with {:ok, bytecode} <- QuickBEAM.compile(rt, source),
           {:ok, parsed} <- Bytecode.decode(bytecode) do
        {:ok, parsed}
      end
    after
      QuickBEAM.stop(rt)
    end
  end

  defp interpreter_result(fun, atoms) do
    isolated(fn ->
      case Interpreter.eval(fun, [], %{gas: @gas}, atoms) do
        {:ok, value} -> {:ok, normalize(value)}
        {:error, reason} -> {:error, reason}
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
            {:error, reason} -> {:error, reason}
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

  defp cache_function_atoms(%Bytecode.Function{} = fun, atoms) do
    Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

    Enum.each(fun.constants, fn
      %Bytecode.Function{} = inner -> cache_function_atoms(inner, atoms)
      _ -> :ok
    end)
  end

  defp classify({:ok, expected}, {:ok, actual}) do
    if equivalent?(expected, actual), do: :compiled, else: :mismatch
  end

  defp classify(_interpreter, {:fallback, _reason}), do: :fallback
  defp classify(_interpreter, {:crash, _reason}), do: :crash
  defp classify({:crash, _}, {:crash, _}), do: :compiled

  defp classify(interpreter, compiler),
    do: if(interpreter == compiler, do: :compiled, else: :mismatch)

  defp equivalent?(:nan, :nan), do: true
  defp equivalent?(a, b), do: a === b

  defp normalize(value) when is_float(value) do
    cond do
      value != value -> :nan
      value == 0.0 and :erlang.float_to_binary(value) == "-0.00000000000000000000e+00" -> -0.0
      true -> value
    end
  end

  defp normalize({:obj, ref}), do: normalize_heap_object(Heap.get_obj(ref))
  defp normalize({:closure, _captures, %Bytecode.Function{}}), do: :function
  defp normalize(%Bytecode.Function{}), do: :function
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
