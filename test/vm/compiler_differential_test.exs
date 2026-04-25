defmodule QuickBEAM.VM.CompilerDifferentialTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.{Bytecode, Compiler, Heap, Interpreter}

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

  defp prepare_function(rt, js) do
    {:ok, bc} = QuickBEAM.compile(rt, js)
    {:ok, parsed} = Bytecode.decode(bc)
    fun = hd(for %Bytecode.Function{} = f <- parsed.value.constants, do: f)
    Process.put({:qb_fn_atoms, fun.byte_code}, parsed.atoms)
    fun
  end

  defp assert_equivalent(rt, js) do
    fun = prepare_function(rt, js)

    compiler_result =
      try do
        case Compiler.invoke(fun, []) do
          {:ok, val} -> {:ok, val}
          :error -> {:error, :compiler_fallback}
        end
      rescue
        e -> {:crash, e}
      end

    interpreter_result =
      try do
        {:ok, Interpreter.invoke(fun, [], 1_000_000_000)}
      rescue
        e -> {:crash, e}
      end

    assert results_equivalent?(compiler_result, interpreter_result),
           """
           #{js}
             compiler:    #{inspect(compiler_result)}
             interpreter: #{inspect(interpreter_result)}
           """
  end

  defp results_equivalent?({:ok, :nan}, {:ok, :nan}), do: true
  defp results_equivalent?({:ok, -0.0}, {:ok, -0.0}), do: true
  defp results_equivalent?({:ok, a}, {:ok, b}), do: a === b
  defp results_equivalent?({:crash, _}, {:crash, _}), do: true
  defp results_equivalent?({:error, :compiler_fallback}, _), do: true
  defp results_equivalent?(_, _), do: false

  describe "arithmetic specializations" do
    test "addition", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 + 2; })")
    end

    test "subtraction", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 - 2; })")
    end

    test "multiplication", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 3 * 4; })")
    end

    test "pre-increment", %{rt: rt} do
      assert_equivalent(rt, "(function(){ var x = 5; return ++x; })")
    end

    test "pre-decrement", %{rt: rt} do
      assert_equivalent(rt, "(function(){ var x = 5; return --x; })")
    end

    test "modulo basic", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 7 % 3; })")
    end

    test "modulo by zero returns NaN", %{rt: rt} do
      assert_equivalent(rt, "(function(){ var x = 1; var y = 0; return x % y; })")
    end

    test "modulo by negative zero returns NaN", %{rt: rt} do
      assert_equivalent(rt, "(function(){ var x = 1; var y = -0; return x % y; })")
    end

    test "negative zero literal", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return -0; })")
    end
  end

  describe "bitwise specializations" do
    test "bitwise AND", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 5 & 3; })")
    end

    test "bitwise OR", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 5 | 3; })")
    end

    test "bitwise XOR", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 5 ^ 3; })")
    end

    test "left shift", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 << 4; })")
    end

    test "left shift overflow wraps (compile-time)", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 << 32; })")
    end

    test "arithmetic right shift negative", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return -1 >> 1; })")
    end

    test "unsigned right shift produces uint32", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return -1 >>> 0; })")
    end

    test "int32 overflow via OR 0", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 2147483648 | 0; })")
    end

    test "float truncated to int32 for bitwise AND", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 & 1.5; })")
    end
  end

  describe "comparison specializations" do
    test "less than", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 < 2; })")
    end

    test "less than or equal", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 2 <= 2; })")
    end

    test "greater than", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 3 > 2; })")
    end

    test "greater than or equal", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 3 >= 3; })")
    end

    test "strict equality same type", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 === 1; })")
    end

    test "strict inequality", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 !== 2; })")
    end

    test "NaN is not equal to itself", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return NaN === NaN; })")
    end

    test "positive zero equals negative zero", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 0 === -0; })")
    end
  end

  describe "string operations" do
    test "string plus number", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return '1' + 2; })")
    end

    test "number plus string", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 1 + '2'; })")
    end

    test "string concatenation", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return 'a' + 'b'; })")
    end
  end

  describe "mixed type coercions" do
    test "boolean plus integer", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return true + 1; })")
    end

    test "null plus integer", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return null + 1; })")
    end

    test "undefined plus integer yields NaN", %{rt: rt} do
      assert_equivalent(rt, "(function(){ return undefined + 1; })")
    end
  end
end
