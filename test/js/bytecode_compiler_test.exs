defmodule QuickBEAM.JS.BytecodeCompilerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.BytecodeCompiler
  alias QuickBEAM.VM.{Compiler, Heap, Interpreter}

  describe "compile/1" do
    test "compiles arithmetic expression scripts" do
      assert_compiles_to("1 + 2 * 3", 7)
    end

    test "compiles local declarations and reads" do
      assert_compiles_to("let x = 1; x + 2", 3)
    end

    test "compiles function declarations and direct calls" do
      assert_compiles_to("function f(a){ return a + 1; } f(2)", 3)
    end

    test "compiles if/else control flow" do
      assert_compiles_to("let x = 0; if (1 > 2) x = 3; else x = 4; x", 4)
    end

    test "compiles constants and unary expressions" do
      assert_compiles_to("'quick'", "quick")
      assert_compiles_to("let x = 2; -x", -2)
      assert_compiles_to("!false", true)
    end

    test "compiles conditional expressions" do
      assert_compiles_to("let x = 1; x === 1 ? 2 : 3", 2)
    end

    test "compiles while loops" do
      assert_compiles_to("let x = 0; while (x < 3) { x = x + 1; } x", 3)
    end

    test "compiles array literals and computed reads" do
      assert_compiles_to("let a = [1, 2, 3]; a.length", 3)
      assert_compiles_to("let a = [1, 2, 3]; a[1]", 2)
    end

    test "compiles object properties" do
      assert_compiles_to("let o = {x: 1, y: 2}; o.x + o.y", 3)
    end

    test "emits loadable object property writes" do
      assert_loads_to("let o = {x: 1}; o.x = 2; o.x", 2)
    end

    test "compiles generic calls and for loops" do
      assert_compiles_to("function f(a,b,c,d){ return a+b+c+d; } f(1,2,3,4)", 10)
      assert_compiles_to("let s=0; for(let i=0; i<4; i=i+1){ s=s+i; } s", 6)
    end

    test "compiles loop break and continue" do
      assert_compiles_to("let x=0; while (x < 5) { x=x+1; break; } x", 1)
      assert_compiles_to("let x=0; let y=0; while (x < 3) { x=x+1; continue; y=9; } x+y", 3)
    end

    test "compiles logical short-circuit expressions" do
      assert_compiles_to("let x=0; true && (x=1); x", 1)
      assert_compiles_to("let x=0; false || (x=1); x", 1)
      assert_compiles_to("null ?? 3", 3)
      assert_compiles_to("0 ?? 3", 0)
    end

    test "compiles update and compound assignments" do
      assert_compiles_to("let x=1; x++; x", 2)
      assert_compiles_to("let x=1; ++x", 2)
      assert_compiles_to("let x=1; x--; x", 0)
      assert_compiles_to("let x=3; x += 4; x", 7)
      assert_compiles_to("let x=6; x *= 7; x", 42)
    end

    test "emits QuickJS-loadable bytecode binaries" do
      assert {:ok, binary} =
               BytecodeCompiler.compile_to_binary("function f(a){ return a + 1; } f(2)")

      assert {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        assert {:ok, 3} = QuickBEAM.load_bytecode(rt, binary)
      after
        QuickBEAM.stop(rt)
      end
    end

    test "keeps the new frontend compiler separate from the VM compiler" do
      assert {:ok, bytecode} = BytecodeCompiler.compile("1 + 2")
      assert %QuickBEAM.VM.Bytecode{} = bytecode
      assert {:ok, 3} = Compiler.invoke(bytecode.value, [])
    end

    test "rewrites simple native QuickJS bytecode binaries" do
      assert {:ok, rt} = QuickBEAM.start(apis: false)

      try do
        assert {:ok, native} = QuickBEAM.compile(rt, "function f(a){ return a + 1; } f(2)")
        assert {:ok, decoded} = QuickBEAM.VM.Bytecode.decode(native)
        assert {:ok, encoded} = QuickBEAM.VM.Bytecode.Writer.encode(decoded)
        assert {:ok, 3} = QuickBEAM.load_bytecode(rt, encoded)
      after
        QuickBEAM.stop(rt)
      end
    end

    test "returns an explicit unsupported error for unresolved globals" do
      assert {:error, {:unsupported, {:unresolved_identifier, "missing"}}} =
               BytecodeCompiler.compile("missing")
    end
  end

  defp assert_loads_to(source, expected) do
    assert {:ok, binary} = BytecodeCompiler.compile_to_binary(source)
    assert {:ok, rt} = QuickBEAM.start(apis: false)

    try do
      assert {:ok, ^expected} = QuickBEAM.load_bytecode(rt, binary)
    after
      QuickBEAM.stop(rt)
    end
  end

  defp assert_compiles_to(source, expected) do
    Task.async(fn ->
      Heap.reset()
      assert {:ok, bytecode} = BytecodeCompiler.compile(source)

      assert {:ok, ^expected} =
               Interpreter.eval(bytecode.value, [], %{gas: 1_000_000}, bytecode.atoms)

      assert {:ok, ^expected} = Compiler.invoke(bytecode.value, [])
    end)
    |> Task.await(30_000)
  end
end
