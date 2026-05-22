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
    assert BEAMForms.is_boolean_guard(left) == {:call, 1, {:atom, 1, :is_boolean}, [left]}

    assert BEAMForms.map_get(left, right) ==
             {:call, 1, {:remote, 1, {:atom, 0, :erlang}, {:atom, 1, :map_get}}, [right, left]}

    assert BEAMForms.map_get?(BEAMForms.map_get(left, BEAMForms.atom(:globals)), :globals)

    assert BEAMForms.map_put(left, right, BEAMForms.integer(1)) ==
             {:call, 1, {:remote, 1, {:atom, 0, :maps}, {:atom, 1, :put}},
              [right, {:integer, 1, 1}, left]}

    assert BEAMForms.map_update(left, right, BEAMForms.integer(1)) ==
             {:map, 1, left, [{:map_field_exact, 1, right, {:integer, 1, 1}}]}
  end

  test "builds binary and function forms" do
    arg = BEAMForms.var(:arg)
    binary = BEAMForms.binary([BEAMForms.binary_element(arg)])

    assert binary == {:bin, 1, [{:bin_element, 1, arg, :default, [:binary]}]}

    assert BEAMForms.function(:identity, [arg], [], [arg]) ==
             {:function, 1, :identity, 1, [{:clause, 1, [arg], [], [arg]}]}

    assert BEAMForms.anonymous_fun([arg], [], [arg]) ==
             {:fun, 1, {:clauses, [{:clause, 1, [arg], [], [arg]}]}}
  end
end
