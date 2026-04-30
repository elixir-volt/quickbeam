defmodule QuickBEAM.JS.Parser.Classes.ConstructorFieldTest do
  use ExUnit.Case, async: true
  @moduletag :quickjs_port

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "ports QuickJS rejection of class fields named constructor" do
    for source <- [
          "class C { constructor = 1; }",
          "class C { static constructor = 2; }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid field name"))
    end
  end
end
