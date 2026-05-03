defmodule QuickBEAM.JS.BytecodeCompilerAudit do
  @moduledoc false

  alias QuickBEAM.JS.BytecodeCompiler
  alias QuickBEAM.VM.{Compiler, Heap, Interpreter}

  def cases do
    [
      {"literal integer", "1"},
      {"arithmetic precedence", "1 + 2 * 3"},
      {"local declaration", "let x = 1; x + 2"},
      {"if consequent", "let x = 0; if (1 < 2) x = 3; x"},
      {"if alternate", "let x = 0; if (1 > 2) x = 3; else x = 4; x"},
      {"while loop", "let x = 0; while (x < 3) { x = x + 1; } x"},
      {"function call", "function f(a){ return a + 1; } f(2)"},
      {"function expression", "let f = function(a){ return a + 1; }; f(2)"},
      {"equality", "let x = 1; x === 1"},
      {"assignment expression", "let x = 1; x = x + 2; x"},
      {"string constant", "'quick'"},
      {"float constant", "1.5"},
      {"unary negation", "let x = 2; -x"},
      {"logical not", "!false"},
      {"conditional expression", "let x = 1; x === 1 ? 2 : 3"},
      {"array length", "let a = [1, 2, 3]; a.length"},
      {"array index", "let a = [1, 2, 3]; a[1]"}
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
      native_loadable:
        Enum.count(results, &(&1.native_load == &1.expected and &1.status != :unsupported)),
      failures: length(results) - Map.get(frequencies, :pass, 0)
    }
  end

  def run_case(name, source) do
    Task.async(fn -> do_run_case(name, source) end)
    |> Task.await(30_000)
  end

  defp do_run_case(name, source) do
    expected = native_eval(source)

    case BytecodeCompiler.compile(source) do
      {:ok, bytecode} ->
        interpreter = run_interpreter(bytecode)
        compiler = run_compiler(bytecode)
        native_load = run_native_load(source)

        status =
          if expected == interpreter and expected == compiler and expected == native_load,
            do: :pass,
            else: :mismatch

        %{
          name: name,
          source: source,
          status: status,
          expected: expected,
          interpreter: interpreter,
          compiler: compiler,
          native_load: native_load
        }

      {:error, {:unsupported, _reason} = reason} ->
        %{name: name, source: source, status: :unsupported, expected: expected, reason: reason}

      {:error, reason} ->
        %{name: name, source: source, status: :error, expected: expected, reason: reason}
    end
  end

  defp native_eval(source) do
    {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      QuickBEAM.eval(rt, source)
    after
      QuickBEAM.stop(rt)
    end
  end

  defp run_interpreter(bytecode) do
    Heap.reset()
    Interpreter.eval(bytecode.value, [], %{gas: 1_000_000}, bytecode.atoms)
  end

  defp run_compiler(bytecode) do
    Compiler.invoke(bytecode.value, [])
  end

  defp run_native_load(source) do
    with {:ok, binary} <- BytecodeCompiler.compile_to_binary(source) do
      {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        QuickBEAM.load_bytecode(rt, binary)
      after
        QuickBEAM.stop(rt)
      end
    end
  end
end
