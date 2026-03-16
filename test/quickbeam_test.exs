defmodule QuickBEAMTest do
  use ExUnit.Case, async: true

  doctest QuickBEAM

  setup do
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

  describe "basic types" do
    test "numbers", %{rt: rt} do
      assert {:ok, 3} = QuickBEAM.eval(rt, "1 + 2")
      assert {:ok, 42} = QuickBEAM.eval(rt, "42")
      assert {:ok, 3.14} = QuickBEAM.eval(rt, "3.14")
    end

    test "booleans", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "true")
      assert {:ok, false} = QuickBEAM.eval(rt, "false")
    end

    test "null and undefined", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "null")
      assert {:ok, nil} = QuickBEAM.eval(rt, "undefined")
    end

    test "strings", %{rt: rt} do
      assert {:ok, "hello"} = QuickBEAM.eval(rt, ~s["hello"])
      assert {:ok, ""} = QuickBEAM.eval(rt, ~s[""])
      assert {:ok, "hello world"} = QuickBEAM.eval(rt, ~s["hello world"])
    end

    test "arrays", %{rt: rt} do
      assert {:ok, [1, 2, 3]} = QuickBEAM.eval(rt, "[1, 2, 3]")
      assert {:ok, []} = QuickBEAM.eval(rt, "[]")
      assert {:ok, ["a", 1, true]} = QuickBEAM.eval(rt, ~s|["a", 1, true]|)
    end

    test "objects", %{rt: rt} do
      assert {:ok, %{"a" => 1}} = QuickBEAM.eval(rt, "({a: 1})")

      assert {:ok, %{"name" => "QuickBEAM", "version" => 1}} =
               QuickBEAM.eval(rt, ~s[({name: "QuickBEAM", version: 1})])
    end
  end

  describe "functions" do
    test "define and call", %{rt: rt} do
      QuickBEAM.eval(rt, "function add(a, b) { return a + b; }")
      assert {:ok, 42} = QuickBEAM.call(rt, "add", [10, 32])
    end

    test "arrow functions", %{rt: rt} do
      QuickBEAM.eval(rt, "globalThis.double = x => x * 2")
      assert {:ok, 84} = QuickBEAM.call(rt, "double", [42])
    end
  end

  describe "errors" do
    test "thrown errors return JSError", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{message: "boom", name: "Error"}} =
               QuickBEAM.eval(rt, ~s[throw new Error("boom")])
    end

    test "reference errors", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{name: "ReferenceError"} = err} =
               QuickBEAM.eval(rt, "undeclaredVar")

      assert err.message =~ "is not defined"
    end

    test "syntax errors", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{name: "SyntaxError"}} =
               QuickBEAM.eval(rt, "if (")
    end

    test "error has stack trace", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{stack: stack}} =
               QuickBEAM.eval(rt, ~s[throw new Error("test")])

      assert is_binary(stack)
      assert stack =~ "<eval>"
    end

    test "thrown non-Error values", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{message: "just a string"}} =
               QuickBEAM.eval(rt, ~s[throw "just a string"])
    end

    test "TypeError", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
               QuickBEAM.eval(rt, "null.foo")
    end
  end

  describe "promises" do
    test "Promise.resolve", %{rt: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, "Promise.resolve(42)")
    end

    test "Promise.reject", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{message: "nope"}} =
               QuickBEAM.eval(rt, "Promise.reject(new Error('nope'))")
    end

    test "async/await", %{rt: rt} do
      assert {:ok, 99} = QuickBEAM.eval(rt, "await Promise.resolve(99)")
    end

    test "chained promises", %{rt: rt} do
      assert {:ok, 6} =
               QuickBEAM.eval(rt, "Promise.resolve(2).then(x => x * 3)")
    end
  end

  describe "timers" do
    test "setTimeout", %{rt: rt} do
      QuickBEAM.eval(
        rt,
        "globalThis.fired = false; setTimeout(() => { globalThis.fired = true; }, 10)"
      )

      Process.sleep(50)
      assert {:ok, true} = QuickBEAM.eval(rt, "globalThis.fired")
    end

    test "setTimeout with delay", %{rt: rt} do
      QuickBEAM.eval(
        rt,
        "globalThis.fired = false; setTimeout(() => { globalThis.fired = true; }, 200)"
      )

      Process.sleep(50)
      assert {:ok, false} = QuickBEAM.eval(rt, "globalThis.fired")
    end
  end

  describe "console" do
    test "console.log outputs to stderr", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, ~s[console.log("test output")])
    end
  end

  describe "reset" do
    test "clears global state", %{rt: rt} do
      QuickBEAM.eval(rt, "globalThis.x = 42")
      assert {:ok, 42} = QuickBEAM.eval(rt, "globalThis.x")

      :ok = QuickBEAM.reset(rt)

      assert {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof globalThis.x")
    end

    test "functions still work after reset", %{rt: rt} do
      :ok = QuickBEAM.reset(rt)
      QuickBEAM.eval(rt, "function sq(x) { return x * x; }")
      assert {:ok, 25} = QuickBEAM.call(rt, "sq", [5])
    end
  end

  describe "Beam.call" do
    test "simple handler" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "double" => fn [n] -> n * 2 end
          }
        )

      assert {:ok, 42} = QuickBEAM.eval(rt, ~s[Beam.call("double", 21)])
      QuickBEAM.stop(rt)
    end

    test "string handler" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "greet" => fn [name] -> "Hello, #{name}!" end
          }
        )

      assert {:ok, "Hello, world!"} = QuickBEAM.eval(rt, ~s[Beam.call("greet", "world")])
      QuickBEAM.stop(rt)
    end

    test "multiple args" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "echo" => fn args -> args end
          }
        )

      assert {:ok, [1, "two", 3]} = QuickBEAM.eval(rt, ~s[Beam.call("echo", 1, "two", 3)])
      QuickBEAM.stop(rt)
    end

    test "chained calls with await" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "add" => fn [a, b] -> a + b end,
            "mul" => fn [a, b] -> a * b end
          }
        )

      assert {:ok, 14} =
               QuickBEAM.eval(rt, """
               const sum = await Beam.call("add", 3, 4);
               const product = await Beam.call("mul", sum, 2);
               product
               """)

      QuickBEAM.stop(rt)
    end
  end

  describe "isolation" do
    test "multiple runtimes are isolated" do
      {:ok, rt1} = QuickBEAM.start()
      {:ok, rt2} = QuickBEAM.start()

      QuickBEAM.eval(rt1, "globalThis.name = 'rt1'")
      QuickBEAM.eval(rt2, "globalThis.name = 'rt2'")

      assert {:ok, "rt1"} = QuickBEAM.eval(rt1, "globalThis.name")
      assert {:ok, "rt2"} = QuickBEAM.eval(rt2, "globalThis.name")

      QuickBEAM.stop(rt1)
      QuickBEAM.stop(rt2)
    end
  end

  describe "introspection" do
    test "globals returns sorted list of all global names" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, globals} = QuickBEAM.globals(rt)
      assert is_list(globals)
      assert "Object" in globals
      assert "Array" in globals
      assert "console" in globals
      assert "Beam" in globals
      assert globals == Enum.sort(globals)
      QuickBEAM.stop(rt)
    end

    test "globals with user_only: true excludes builtins" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, empty} = QuickBEAM.globals(rt, user_only: true)
      assert empty == []

      QuickBEAM.eval(rt, "globalThis.myThing = 123; globalThis.myOther = 'hi'")
      {:ok, user} = QuickBEAM.globals(rt, user_only: true)
      assert "myThing" in user
      assert "myOther" in user
      refute "Object" in user
      refute "console" in user
      QuickBEAM.stop(rt)
    end

    test "get_global returns primitive values" do
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "globalThis.n = 42; globalThis.s = 'hello'; globalThis.b = true")

      assert {:ok, 42} = QuickBEAM.get_global(rt, "n")
      assert {:ok, "hello"} = QuickBEAM.get_global(rt, "s")
      assert {:ok, true} = QuickBEAM.get_global(rt, "b")
      QuickBEAM.stop(rt)
    end

    test "get_global returns nil for undefined" do
      {:ok, rt} = QuickBEAM.start()
      assert {:ok, nil} = QuickBEAM.get_global(rt, "nonexistent")
      QuickBEAM.stop(rt)
    end

    test "get_global returns map for objects" do
      {:ok, rt} = QuickBEAM.start()
      QuickBEAM.eval(rt, "globalThis.obj = { x: 1, y: 2 }")
      assert {:ok, %{"x" => 1, "y" => 2}} = QuickBEAM.get_global(rt, "obj")
      QuickBEAM.stop(rt)
    end

    test "info returns handlers, memory, and global count" do
      {:ok, rt} = QuickBEAM.start(handlers: %{"greet" => fn [n] -> "Hi #{n}" end})
      QuickBEAM.eval(rt, "globalThis.x = 1")

      info = QuickBEAM.info(rt)
      assert info.handlers == ["greet"]
      assert is_integer(info.memory.memory_used_size)
      assert info.memory.memory_used_size > 0
      assert is_integer(info.global_count)
      assert info.global_count > 0
      QuickBEAM.stop(rt)
    end
  end

  describe "bytecode" do
    test "compile returns binary" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, bytecode} = QuickBEAM.compile(rt, "1 + 2")
      assert is_binary(bytecode)
      assert byte_size(bytecode) > 0
      QuickBEAM.stop(rt)
    end

    test "compile and load_bytecode round-trip" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, bytecode} = QuickBEAM.compile(rt, "40 + 2")
      {:ok, result} = QuickBEAM.load_bytecode(rt, bytecode)
      assert result == 42
      QuickBEAM.stop(rt)
    end

    test "bytecode transfers between runtimes" do
      {:ok, rt1} = QuickBEAM.start()
      {:ok, bytecode} = QuickBEAM.compile(rt1, "function mul(a, b) { return a * b }")
      QuickBEAM.stop(rt1)

      {:ok, rt2} = QuickBEAM.start()
      {:ok, _} = QuickBEAM.load_bytecode(rt2, bytecode)
      {:ok, result} = QuickBEAM.call(rt2, "mul", [6, 7])
      assert result == 42
      QuickBEAM.stop(rt2)
    end

    test "compile reports syntax errors" do
      {:ok, rt} = QuickBEAM.start()
      {:error, %QuickBEAM.JSError{}} = QuickBEAM.compile(rt, "function {")
      QuickBEAM.stop(rt)
    end

    test "bytecode is compact binary" do
      {:ok, rt} = QuickBEAM.start()

      {:ok, bytecode} =
        QuickBEAM.compile(rt, """
        function fibonacci(n) {
          if (n <= 1) return n;
          return fibonacci(n - 1) + fibonacci(n - 2);
        }
        """)

      assert is_binary(bytecode)
      assert byte_size(bytecode) < 1024
      QuickBEAM.stop(rt)
    end

    test "compiled globals persist after load" do
      {:ok, rt} = QuickBEAM.start()
      {:ok, bytecode} = QuickBEAM.compile(rt, "globalThis.answer = 42")
      {:ok, 42} = QuickBEAM.load_bytecode(rt, bytecode)
      {:ok, 42} = QuickBEAM.eval(rt, "answer")
      QuickBEAM.stop(rt)
    end
  end

  describe "disasm" do
    test "disasm/1 decodes bytecode without a runtime" do
      {:ok, rt} = QuickBEAM.start(apis: false)
      {:ok, bytecode} = QuickBEAM.compile(rt, "1 + 2")
      QuickBEAM.stop(rt)

      {:ok, %QuickBEAM.Bytecode{} = bc} = QuickBEAM.disasm(bytecode)
      assert bc.name == "<eval>"
      assert bc.stack_size > 0
      assert length(bc.opcodes) > 0
    end

    test "disasm/2 compiles and disassembles in one call" do
      {:ok, rt} = QuickBEAM.start(apis: false)

      {:ok, %QuickBEAM.Bytecode{} = bc} =
        QuickBEAM.disasm(rt, "function add(a, b) { return a + b }")

      [%QuickBEAM.Bytecode{} = add_fn] = bc.cpool
      assert add_fn.name == "add"
      assert add_fn.args == ["a", "b"]
      assert add_fn.arg_count == 2
      assert Enum.any?(add_fn.opcodes, fn op -> elem(op, 1) == "add" end)
      assert Enum.any?(add_fn.opcodes, fn op -> elem(op, 1) == "return" end)
      QuickBEAM.stop(rt)
    end

    test "nested functions in constant pool" do
      {:ok, rt} = QuickBEAM.start(apis: false)

      {:ok, bc} =
        QuickBEAM.disasm(rt, "function outer() { return function inner() { return 42 } }")

      outer = hd(bc.cpool)
      assert outer.name == "outer"
      inner = hd(outer.cpool)
      assert inner.name == "inner"
      QuickBEAM.stop(rt)
    end

    test "closure variables are reported" do
      {:ok, rt} = QuickBEAM.start(apis: false)

      {:ok, bc} =
        QuickBEAM.disasm(rt, "function counter() { let n = 0; return () => ++n }")

      counter = hd(bc.cpool)
      arrow = hd(counter.cpool)
      assert [%{"name" => "n", "kind" => "let", "type" => "local"} | _] = arrow.closure_vars
      QuickBEAM.stop(rt)
    end

    test "error on invalid bytecode" do
      assert {:error, _} = QuickBEAM.disasm("garbage")
      assert {:error, _} = QuickBEAM.disasm(<<>>)
    end

    test "source text included when available" do
      {:ok, rt} = QuickBEAM.start(apis: false)

      {:ok, bc} = QuickBEAM.disasm(rt, "function hello() { return 'world' }")

      fn_bc = hd(bc.cpool)
      assert fn_bc.source =~ "hello"
      QuickBEAM.stop(rt)
    end

    test "opcodes include byte offsets" do
      {:ok, rt} = QuickBEAM.start(apis: false)
      {:ok, bc} = QuickBEAM.disasm(rt, "1 + 2")

      Enum.each(bc.opcodes, fn op ->
        assert is_integer(elem(op, 0))
        assert is_binary(elem(op, 1))
      end)

      QuickBEAM.stop(rt)
    end
  end

  describe "resource limits" do
    test "max_stack_size allows deeper recursion" do
      code = "function deep(n) { return n <= 0 ? 0 : deep(n - 1) }; deep(500)"

      {:ok, rt_small} = QuickBEAM.start(max_stack_size: 256 * 1024)
      {:error, %QuickBEAM.JSError{name: "RangeError"}} = QuickBEAM.eval(rt_small, code)
      QuickBEAM.stop(rt_small)

      {:ok, rt_large} = QuickBEAM.start(max_stack_size: 64 * 1024 * 1024)
      assert {:ok, 0} = QuickBEAM.eval(rt_large, code)
      QuickBEAM.stop(rt_large)
    end

    test "memory_limit caps allocation" do
      {:ok, rt} = QuickBEAM.start(memory_limit: 1024 * 1024)

      {:error, %QuickBEAM.JSError{}} =
        QuickBEAM.eval(rt, "new Array(100000).fill('x'.repeat(100))")

      QuickBEAM.stop(rt)
    end
  end
end
