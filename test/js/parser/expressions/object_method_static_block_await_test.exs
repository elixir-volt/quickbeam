defmodule QuickBEAM.JS.Parser.Expressions.ObjectMethodStaticBlockAwaitTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "treats await as an identifier inside non-async object methods nested in static blocks" do
    for source <- [
          "class C { static { ({ method(x = await) { return await; } }); } }",
          "class C { static { ({ *method(x = await) { return await; } }); } }",
          "class C { static { ({ get value() { return await; } }); } }"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
