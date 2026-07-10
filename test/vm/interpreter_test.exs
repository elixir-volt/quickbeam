defmodule QuickBEAM.VM.InterpreterTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Continuation, Interpreter, Program}

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

  test "keeps mutable captured variables alive after their defining frame returns" do
    source = """
    (function(counter) { return counter() + counter() })(
      (function() { let x=1; return function() { x++; return x } })()
    )
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 5} = QuickBEAM.VM.eval(program)
  end

  test "forwards captured cells through nested closures" do
    source = "(function(x){return function(){return function(){x++;return x}}})(40)()()"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 41} = QuickBEAM.VM.eval(program)
  end

  test "isolates captured-variable cells across concurrent evaluations" do
    source = "(function(){let x=0;return function(){return ++x}})()()"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    tasks = for _ <- 1..40, do: Task.async(fn -> QuickBEAM.VM.eval(program) end)
    assert Task.await_many(tasks) == List.duplicate({:ok, 1}, 40)
  end

  test "executes array callback methods with resumable native frames" do
    source = "[1,2,3,4].map(x=>x*2).filter(x=>x>4).reduce((sum,x)=>sum+x,0)"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 14} = QuickBEAM.VM.eval(program)

    assert {:ok, some} = QuickBEAM.VM.compile("[1,2,3].some(x=>x===2)")
    assert {:ok, true} = QuickBEAM.VM.eval(some)
  end

  test "supports arguments slicing, sets, regular expressions, and function prototypes" do
    source = "(function(){return [].slice.call(arguments,1).join('-')})('a','b','c')"
    assert {:ok, arguments} = QuickBEAM.VM.compile(source)
    assert {:ok, "b-c"} = QuickBEAM.VM.eval(arguments)

    assert {:ok, set} = QuickBEAM.VM.compile("new Set(['present']).has('present')")
    assert {:ok, true} = QuickBEAM.VM.eval(set)

    assert {:ok, regexp} = QuickBEAM.VM.compile("/beam/.test('quickbeam')")
    assert {:ok, true} = QuickBEAM.VM.eval(regexp)

    assert {:ok, prototype} =
             QuickBEAM.VM.compile(
               "{function Example(){}; Example.prototype.answer=42; Example.prototype.answer}"
             )

    assert {:ok, 42} = QuickBEAM.VM.eval(prototype)
  end

  test "evaluates and exports object and array values" do
    source = "{let object={answer: 41}; object.answer++; [object.answer, [1,2,3].length]}"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, [42, 3]} = QuickBEAM.VM.eval(program)
  end

  test "isolates object heaps across concurrent evaluations" do
    source = "{let object={count: input}; object.count++; object.count}"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    tasks =
      for input <- 1..40 do
        Task.async(fn -> QuickBEAM.VM.eval(program, vars: %{"input" => input}) end)
      end

    assert Task.await_many(tasks) == Enum.map(1..40, &{:ok, &1 + 1})
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
    source = "(function recurse(n){return 1+recurse(n+1)})(0)"
    assert {:ok, program} = QuickBEAM.VM.compile(source)

    assert {:error, {:limit_exceeded, :stack_depth, 6}} =
             QuickBEAM.VM.eval(program, max_stack_depth: 5)
  end

  test "replaces the current frame for QuickJS tail calls" do
    source = "(function recurse(n){if(n===0)return 0;return recurse(n-1)})(1000)"
    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 0} = QuickBEAM.VM.eval(program, max_stack_depth: 2)
  end

  test "terminates an evaluation process at the wall-clock deadline" do
    assert {:ok, program} = QuickBEAM.VM.compile("while (true) {}")

    assert {:error, {:limit_exceeded, :timeout, 10}} =
             QuickBEAM.VM.eval(program, max_steps: 1_000_000_000, timeout: 10)

    assert {:ok, finite} = QuickBEAM.VM.compile("40 + 2")
    assert {:ok, 42} = QuickBEAM.VM.eval(finite)
  end

  test "unwinds JavaScript throws to same-frame and caller-frame catch handlers" do
    sources = [
      "try { throw 41 } catch (error) { error + 1 }",
      "(function(){try{return (function(){throw 41})()}catch(error){return error+1}})()"
    ]

    for source <- sources do
      assert {:ok, program} = QuickBEAM.VM.compile(source)
      assert {:ok, 42} = QuickBEAM.VM.eval(program)
    end
  end

  test "executes finally subroutines while preserving return and throw completion" do
    assert {:ok, returning} = QuickBEAM.VM.compile("(function(){try{return 42}finally{1}})()")
    assert {:ok, 42} = QuickBEAM.VM.eval(returning)

    assert {:ok, throwing} = QuickBEAM.VM.compile("try { throw 42 } finally { 1 }")

    assert {:error, %QuickBEAM.JSError{name: "Error", message: "42"}} =
             QuickBEAM.VM.eval(throwing)
  end

  test "catches reference and call errors as JavaScript exceptions" do
    assert {:ok, reference_error} = QuickBEAM.VM.compile("try { missing } catch (error) { 42 }")
    assert {:ok, 42} = QuickBEAM.VM.eval(reference_error)

    assert {:ok, type_error} = QuickBEAM.VM.compile("try { (1)() } catch (error) { 42 }")
    assert {:ok, 42} = QuickBEAM.VM.eval(type_error)
  end

  test "does not expose VM resource limits to JavaScript catch handlers" do
    assert {:ok, program} = QuickBEAM.VM.compile("try { while(true) {} } catch (error) { 42 }")

    assert {:error, {:limit_exceeded, :steps, 100}} =
             QuickBEAM.VM.eval(program, max_steps: 100)
  end

  test "captures and resumes the full caller stack across a nested await" do
    source = "(async function(){ return await marker })()"
    assert {:ok, %Program{} = program} = QuickBEAM.VM.compile(source)
    pending = {:pending, make_ref()}

    assert {:suspended, %Continuation{} = continuation} =
             Interpreter.eval(program, vars: %{"marker" => pending}, max_steps: 100)

    assert [_caller] = continuation.execution.callers
    assert {:ok, "resumed"} = Interpreter.resume(continuation, {:ok, "resumed"})
  end

  test "unwinds a rejected nested await into an outer catch handler" do
    source = """
    (async function() {
      try {
        return await (async function() { await 0; throw 41 })()
      } catch (error) {
        return error + 1
      }
    })()
    """

    assert {:ok, program} = QuickBEAM.VM.compile(source)
    assert {:ok, 42} = QuickBEAM.VM.eval(program)
  end

  test "reports unsupported opcodes without crashing the caller" do
    assert {:ok, program} = QuickBEAM.VM.compile("class UnsupportedClass {}")
    assert {:error, {:unsupported_opcode, _opcode, _operands}} = QuickBEAM.VM.eval(program)
    assert Process.alive?(self())
  end
end
