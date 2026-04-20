defmodule QuickBEAM.BeamVM.CompilerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.BeamVM.{Bytecode, Compiler, Heap, Interpreter}

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
    parsed
  end

  defp user_function(parsed) do
    case for %Bytecode.Function{} = fun <- parsed.value.constants, do: fun do
      [fun | _] -> fun
      [] -> parsed.value
    end
  end

  describe "compile/1" do
    test "compiles a straight-line arithmetic function", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a,b){return a+b})") |> user_function()

      assert {:ok, {_mod, :run}} = Compiler.compile(fun)
      assert {:ok, 7} = Compiler.invoke(fun, [3, 4])
    end

    test "compiles locals and reassignment in straight-line code", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(a){let x=1; x=x+a; return x})") |> user_function()

      assert {:ok, 6} = Compiler.invoke(fun, [5])
    end

    test "rejects unsupported opcodes", %{rt: rt} do
      fun = compile_and_decode(rt, "(function(obj){return obj.x})") |> user_function()

      assert {:error, {:unsupported_opcode, :get_field}} = Compiler.compile(fun)
    end
  end

  describe "Interpreter integration" do
    test "eligible functions use the compiled cache", %{rt: rt} do
      parsed = compile_and_decode(rt, "(function(a,b){return a+b})")
      fun = user_function(parsed)

      assert 9 == Interpreter.invoke(fun, [4, 5], 1_000)
      assert {:compiled, {_mod, :run}} = Heap.get_compiled({fun.byte_code, fun.arg_count})
    end
  end
end
