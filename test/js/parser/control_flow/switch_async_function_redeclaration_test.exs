defmodule QuickBEAM.JS.Parser.ControlFlow.SwitchAsyncFunctionRedeclarationTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects switch redeclarations involving async or generator declarations" do
    for source <- [
          "switch (x) { case 0: async function f() {} default: async function f() {} }",
          "switch (x) { case 0: function f() {} default: async function f() {} }",
          "switch (x) { case 0: function* f() {} default: function f() {} }",
          "switch (x) { case 0: async function* f() {} default: function* f() {} }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "duplicate lexical declaration"))
    end
  end
end
