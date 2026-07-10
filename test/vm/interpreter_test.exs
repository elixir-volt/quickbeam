defmodule QuickBEAM.VM.InterpreterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Continuation, Interpreter, Opcodes, Program}

  test "evaluates arithmetic and comparisons in an isolated BEAM process" do
    assert {:ok, program} = QuickBEAM.VM.compile("(2 + 3 * 4) === 14")
    assert {:ok, true} = QuickBEAM.VM.eval(program)
  end

  test "evaluates lexical locals and control-flow loops" do
    source = "{ let sum=0; for(let i=0;i<10;i++) sum+=i; sum }"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 45} = QuickBEAM.VM.eval(program)
  end

  test "invokes bytecode functions with arguments" do
    assert {:ok, program} = QuickBEAM.VM.compile("(function(a,b){return a*b})(6,7)")
    assert {:ok, 42} = QuickBEAM.VM.eval(program)
  end

  test "injects independent globals for each evaluation" do
    assert {:ok, program} = QuickBEAM.VM.compile("input + 1")

    tasks =
      for input <- 1..20 do
        Task.async(fn -> QuickBEAM.VM.eval(program, vars: %{"input" => input}) end)
      end

    assert Task.await_many(tasks) == Enum.map(1..20, &{:ok, &1 + 1})
  end

  test "enforces the deterministic instruction budget" do
    assert {:ok, program} = QuickBEAM.VM.compile("while (true) {}")

    assert {:error, {:limit_exceeded, :steps, 100}} =
             QuickBEAM.VM.eval(program, max_steps: 100, timeout: 1_000)
  end

  test "enforces the JavaScript call-stack depth independently of the BEAM stack" do
    source = "(function recurse(n){return recurse(n+1)})(0)"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:error, {:limit_exceeded, :stack_depth, 6}} =
             QuickBEAM.VM.eval(program, max_stack_depth: 5)
  end

  test "terminates an evaluation process at the wall-clock deadline" do
    assert {:ok, program} = QuickBEAM.VM.compile("while (true) {}")

    assert {:error, {:limit_exceeded, :timeout, 10}} =
             QuickBEAM.VM.eval(program, max_steps: 1_000_000_000, timeout: 10)

    assert {:ok, finite} = QuickBEAM.VM.compile("40 + 2")
    assert {:ok, 42} = QuickBEAM.VM.eval(finite)
  end

  test "captures and resumes an explicit await continuation" do
    assert {:ok, %Program{} = program} = QuickBEAM.VM.compile("0")
    reference = make_ref()
    root = program.root

    instructions = {
      {Opcodes.num(:push_const), [0]},
      {Opcodes.num(:await), []},
      {Opcodes.num(:return), []}
    }

    root = %{
      root
      | constants: [{:pending, reference}],
        instructions: instructions,
        source_positions: {{1, 1}, {1, 1}, {1, 1}}
    }

    assert {:suspended, %Continuation{} = continuation} =
             Interpreter.eval(%{program | root: root}, max_steps: 10)

    assert {:ok, "resumed"} = Interpreter.resume(continuation, {:ok, "resumed"})
  end

  test "reports unsupported opcodes without crashing the caller" do
    assert {:ok, program} = QuickBEAM.VM.compile("({answer: 42})")
    assert {:error, {:unsupported_opcode, _opcode, _operands}} = QuickBEAM.VM.eval(program)
    assert Process.alive?(self())
  end
end
