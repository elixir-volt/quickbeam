defmodule QuickBEAMTest do
  use ExUnit.Case, async: true

  doctest QuickBEAM

  setup do
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      if Process.alive?(rt), do: QuickBEAM.stop(rt)
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

  describe "beam.call" do
    test "simple handler" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "double" => fn [n] -> n * 2 end
          }
        )

      assert {:ok, 42} = QuickBEAM.eval(rt, ~s[beam.call("double", 21)])
      QuickBEAM.stop(rt)
    end

    test "string handler" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "greet" => fn [name] -> "Hello, #{name}!" end
          }
        )

      assert {:ok, "Hello, world!"} = QuickBEAM.eval(rt, ~s[beam.call("greet", "world")])
      QuickBEAM.stop(rt)
    end

    test "multiple args" do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "echo" => fn args -> args end
          }
        )

      assert {:ok, [1, "two", 3]} = QuickBEAM.eval(rt, ~s[beam.call("echo", 1, "two", 3)])
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
               const sum = await beam.call("add", 3, 4);
               const product = await beam.call("mul", sum, 2);
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
end
