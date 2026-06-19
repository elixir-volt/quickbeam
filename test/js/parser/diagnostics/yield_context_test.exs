defmodule QuickBEAM.JS.Parser.Diagnostics.YieldContextTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS module yield expression context diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("yield value;", source_type: :module)

    assert Enum.any?(errors, &(&1.message == "yield expression not within generator"))
  end

  test "ports QuickJS non-generator function yield identifier syntax" do
    assert {:ok, %AST.Program{body: [%AST.FunctionDeclaration{}]}} =
             Parser.parse("function f() { var yield = 1; yield; }")
  end
end
