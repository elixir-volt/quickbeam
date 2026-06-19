defmodule QuickBEAM.JS.Parser.Classes.StaticBlockBindingContextTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects await bindings and labels in static blocks" do
    for source <- [
          "class C { static { await: 0; } }",
          "class C { static { function await() {} } }",
          "class C { static { try {} catch (await) {} } }"
        ] do
      assert {:error, %AST.Program{}, [_ | _]} = Parser.parse(source)
    end
  end
end
