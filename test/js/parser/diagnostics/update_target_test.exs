defmodule QuickBEAM.JS.Parser.Diagnostics.UpdateTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects this as an update target" do
    for source <- ["++this;", "this++;", "--this;", "this--;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid assignment target"))
    end
  end

  test "does not parse postfix update operators across line terminators" do
    for source <- ["x\n++;", "x\u2028++;", "x\u2029--;"] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert errors != []
    end
  end
end
