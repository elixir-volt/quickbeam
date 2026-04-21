defmodule QuickBEAM.VM.Compiler.OptimizerTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.Optimizer
  alias QuickBEAM.VM.Opcodes

  test "folds integer literal arithmetic" do
    instructions = [
      {Opcodes.num(:push_i32), [2]},
      {Opcodes.num(:push_i32), [3]},
      {Opcodes.num(:add), []},
      {Opcodes.num(:return), []}
    ]

    optimized = Optimizer.optimize(instructions)

    assert Enum.at(optimized, 0) == {Opcodes.num(:push_i32), [5]}
    assert Enum.at(optimized, 1) == {Opcodes.num(:nop), []}
    assert Enum.at(optimized, 2) == {Opcodes.num(:nop), []}
    assert Enum.at(optimized, 3) == {Opcodes.num(:return), []}
  end

  test "rewrites simple local increments" do
    instructions = [
      {Opcodes.num(:get_loc), [0]},
      {Opcodes.num(:push_1), [1]},
      {Opcodes.num(:add), []},
      {Opcodes.num(:put_loc), [0]},
      {Opcodes.num(:return_undef), []}
    ]

    optimized = Optimizer.optimize(instructions)

    assert Enum.at(optimized, 2) == {Opcodes.num(:inc_loc), [0]}
    assert Enum.at(optimized, 3) == {Opcodes.num(:nop), []}
  end

  test "simplifies constant branches" do
    instructions = [
      {Opcodes.num(:push_true), []},
      {Opcodes.num(:if_false8), [4]},
      {Opcodes.num(:push_i32), [1]},
      {Opcodes.num(:return), []},
      {Opcodes.num(:push_i32), [2]},
      {Opcodes.num(:return), []}
    ]

    optimized = Optimizer.optimize(instructions)

    assert Enum.at(optimized, 0) == {Opcodes.num(:nop), []}
    assert Enum.at(optimized, 1) == {Opcodes.num(:nop), []}
  end

  test "rewrites forwarding block targets" do
    instructions = [
      {Opcodes.num(:push_true), []},
      {Opcodes.num(:if_true8), [4]},
      {Opcodes.num(:goto16), [5]},
      {Opcodes.num(:return_undef), []},
      {Opcodes.num(:goto16), [6]},
      {Opcodes.num(:return_undef), []},
      {Opcodes.num(:push_i32), [1]},
      {Opcodes.num(:return), []}
    ]

    optimized = Optimizer.optimize(instructions)

    assert Enum.at(optimized, 1) == {Opcodes.num(:goto16), [6]}
  end
end
