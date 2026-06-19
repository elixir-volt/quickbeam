defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.CallsTest do
  use QuickBEAM.VM.TestCase, async: true

  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Calls
  alias QuickBEAM.VM.Interpreter.Context

  test "call helpers invoke builtins with compiled context" do
    fun = {:builtin, "add", fn [a, b], _this -> a + b end}

    assert Calls.invoke_runtime(%Context{}, fun, [2, 3]) == 5
  end

  test "eval_or_call dispatches non-eval calls normally" do
    fun = {:builtin, "id", fn [value], _this -> value end}
    ctx = %Context{globals: %{"eval" => :not_eval}}

    assert Calls.eval_or_call(ctx, fun, [7]) == 7
  end

  test "constructor helper checks derived return values", %{rt: rt} do
    assert_modes(
      rt,
      "class A { constructor(){ this.x = 1 } } class B extends A { constructor(){ super(); return {x: 2} } } new B().x",
      2
    )
  end
end
