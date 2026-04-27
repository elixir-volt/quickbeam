defmodule QuickBEAM.JS.Parser.Diagnostics.NewTargetContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS top-level new.target diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("new.target;")

    assert Enum.any?(errors, &(&1.message == "new.target not allowed outside function"))
  end

  test "ports QuickJS new.target declaration initializer diagnostics" do
    assert {:error, %AST.Program{body: [%AST.VariableDeclaration{}]}, errors} =
             Parser.parse("let value = new.target;")

    assert Enum.any?(errors, &(&1.message == "new.target not allowed outside function"))
  end
end
