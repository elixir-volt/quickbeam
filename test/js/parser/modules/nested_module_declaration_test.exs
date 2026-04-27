defmodule QuickBEAM.JS.Parser.Modules.NestedModuleDeclarationTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS import declaration top-level diagnostics" do
    assert {:error, %AST.Program{body: [%AST.BlockStatement{}]}, errors} =
             Parser.parse(~s({ import value from "mod"; }), source_type: :module)

    assert Enum.any?(
             errors,
             &(&1.message == "import/export declarations only allowed at top level")
           )
  end

  test "ports QuickJS export declaration top-level diagnostics" do
    assert {:error, %AST.Program{body: [%AST.FunctionDeclaration{}]}, errors} =
             Parser.parse("function f() { export const value = 1; }", source_type: :module)

    assert Enum.any?(
             errors,
             &(&1.message == "import/export declarations only allowed at top level")
           )
  end
end
