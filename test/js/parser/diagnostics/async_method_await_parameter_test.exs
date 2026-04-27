defmodule QuickBEAM.JS.Parser.Diagnostics.AsyncMethodAwaitParameterTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS async object method await parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ExpressionStatement{}]}, errors} =
             Parser.parse("object = { async method(await) {} };")

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end

  test "ports QuickJS async class method await parameter diagnostics" do
    assert {:error, %AST.Program{body: [%AST.ClassDeclaration{}]}, errors} =
             Parser.parse("class C { async method(await) {} }")

    assert Enum.any?(errors, &(&1.message == "await parameter not allowed in async function"))
  end
end
