defmodule QuickBEAM.VM.Compiler.BEAMFormsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.BEAMForms

  test "builds simple abstract forms" do
    left = BEAMForms.var(:left)
    right = BEAMForms.var(:right)

    assert BEAMForms.equal(left, right) == {:op, 1, :==, left, right}
    assert BEAMForms.not_equal(left, right) == {:op, 1, :"=/=", left, right}
    assert BEAMForms.or_else(left, right) == {:op, 1, :orelse, left, right}
    assert BEAMForms.is_number_guard(left) == {:call, 1, {:atom, 1, :is_number}, [left]}
  end

  test "builds binary and function forms" do
    arg = BEAMForms.var(:arg)
    binary = BEAMForms.binary([BEAMForms.binary_element(arg)])

    assert binary == {:bin, 1, [{:bin_element, 1, arg, :default, [:binary]}]}

    assert BEAMForms.function(:identity, [arg], [], [arg]) ==
             {:function, 1, :identity, 1, [{:clause, 1, [arg], [], [arg]}]}
  end
end
