defmodule QuickBEAM.JS.Parser.Diagnostics.GeneratorYieldNoInTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects yield operands containing in inside for init no-in context" do
    for source <- [
          "function* g() { for (yield '' in {}; ; ) ; }",
          "function* g() { for (yield * '' in {}; ; ) ; }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "yield expression not allowed here"))
    end
  end
end
