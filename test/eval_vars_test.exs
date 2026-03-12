defmodule QuickBEAM.EvalVarsTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "eval with vars" do
    test "string variable", %{rt: rt} do
      assert {:ok, "HELLO"} = QuickBEAM.eval(rt, "name.toUpperCase()", vars: %{"name" => "hello"})
    end

    test "number variables", %{rt: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, "a + b", vars: %{"a" => 10, "b" => 32})
    end

    test "boolean variable", %{rt: rt} do
      assert {:ok, "yes"} = QuickBEAM.eval(rt, "flag ? 'yes' : 'no'", vars: %{"flag" => true})
    end

    test "null variable", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "value === null", vars: %{"value" => nil})
    end

    test "array variable", %{rt: rt} do
      assert {:ok, 3} = QuickBEAM.eval(rt, "items.length", vars: %{"items" => [1, 2, 3]})
    end

    test "object variable", %{rt: rt} do
      assert {:ok, "Alice"} =
               QuickBEAM.eval(rt, "user.name", vars: %{"user" => %{"name" => "Alice", "age" => 30}})
    end

    test "nested object", %{rt: rt} do
      data = %{"order" => %{"items" => [%{"sku" => "A"}, %{"sku" => "B"}]}}

      assert {:ok, "A,B"} =
               QuickBEAM.eval(rt, "data.order.items.map(i => i.sku).join(',')", vars: %{"data" => data})
    end

    test "multiple vars", %{rt: rt} do
      assert {:ok, "Alice is 30"} =
               QuickBEAM.eval(rt, "`${name} is ${age}`", vars: %{"name" => "Alice", "age" => 30})
    end

    test "vars don't leak after eval", %{rt: rt} do
      QuickBEAM.eval(rt, "name.toUpperCase()", vars: %{"name" => "test"})
      assert {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof name")
    end

    test "vars don't leak after error", %{rt: rt} do
      QuickBEAM.eval(rt, "throw new Error('boom')", vars: %{"leaked" => true})
      assert {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof leaked")
    end

    test "vars don't overwrite existing globals", %{rt: rt} do
      QuickBEAM.eval(rt, "globalThis.keep = 'original'")
      QuickBEAM.eval(rt, "keep + ' ' + extra", vars: %{"extra" => "added"})
      assert {:ok, "original"} = QuickBEAM.eval(rt, "keep")
    end

    test "top-level await with vars", %{rt: rt} do
      assert {:ok, 42} =
               QuickBEAM.eval(rt, "await Promise.resolve(x * 2)", vars: %{"x" => 21})
    end

    test "empty vars map behaves like normal eval", %{rt: rt} do
      assert {:ok, 3} = QuickBEAM.eval(rt, "1 + 2", vars: %{})
    end

    test "works with timeout option", %{rt: rt} do
      assert {:ok, "OK"} =
               QuickBEAM.eval(rt, "'OK'", vars: %{"x" => 1}, timeout: 5000)
    end

    test "timeout still fires with vars", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{message: "interrupted"}} =
               QuickBEAM.eval(rt, "while(x) {}", vars: %{"x" => true}, timeout: 200)
    end

    test "vars are scoped per call", %{rt: rt} do
      assert {:ok, "A"} = QuickBEAM.eval(rt, "v", vars: %{"v" => "A"})
      assert {:ok, "B"} = QuickBEAM.eval(rt, "v", vars: %{"v" => "B"})
      assert {:ok, "undefined"} = QuickBEAM.eval(rt, "typeof v")
    end
  end
end
