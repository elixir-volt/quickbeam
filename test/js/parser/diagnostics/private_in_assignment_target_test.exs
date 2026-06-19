defmodule QuickBEAM.JS.Parser.Diagnostics.PrivateInAssignmentTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows private-in expressions as assignment targets for QuickJS parity" do
    source = "class C { #field; constructor() { #field in {} = 0; } }"
    assert {:ok, %AST.Program{}} = Parser.parse(source)
  end

  test "rejects yield as private-in right-hand side" do
    source = "class C { #field; static method() { #field in yield; } }"

    assert {:error, %AST.Program{}, errors} = Parser.parse(source)
    assert Enum.any?(errors, &(&1.message == "invalid private in expression"))
  end

  test "rejects yield references in strict in-expression right-hand sides" do
    assert {:error, %AST.Program{}, errors} = Parser.parse(~S|"use strict"; '' in (yield);|)
    assert errors != []
  end
end
