defmodule QuickBEAM.JS.Parser.Diagnostics.ReservedNamesTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS sloppy future reserved binding names" do
    for name <- ~w[let static] do
      assert {:ok, %AST.Program{body: [%AST.VariableDeclaration{}]}} =
               Parser.parse("var #{name};")
    end
  end

  test "ports QuickJS strict future reserved binding name diagnostics" do
    for name <- ~w[let static] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(~s|"use strict"; var #{name};|)
      assert Enum.any?(errors, &(&1.message == "restricted binding name in strict mode"))
    end
  end

  test "ports QuickJS await contextual binding name allowance" do
    assert {:ok,
            %AST.Program{
              body: [
                %AST.VariableDeclaration{
                  declarations: [%AST.VariableDeclarator{id: %AST.Identifier{name: "await"}}]
                }
              ]
            }} =
             Parser.parse("var await;")
  end
end
