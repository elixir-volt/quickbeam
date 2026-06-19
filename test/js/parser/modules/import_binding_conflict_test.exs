defmodule QuickBEAM.JS.Parser.Modules.ImportBindingConflictTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS duplicate import binding diagnostics" do
    source = ~s(import { value } from "a"; import { other as value } from "b";)

    assert {:error, %AST.Program{body: [%AST.ImportDeclaration{}, %AST.ImportDeclaration{}]},
            errors} =
             Parser.parse(source, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end

  test "ports QuickJS import binding conflict with lexical declaration diagnostics" do
    source = ~s(import value from "a"; let value;)

    assert {:error, %AST.Program{body: [%AST.ImportDeclaration{}, %AST.VariableDeclaration{}]},
            errors} =
             Parser.parse(source, source_type: :module)

    assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
  end
end
